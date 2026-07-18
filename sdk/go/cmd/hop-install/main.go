// Command hop-install installs one signed libhop release outside Go's read-only module cache.
package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	pathpkg "path"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

const (
	currentVersion      = "v0.0.1"
	manifestSchema      = "https://hopme.sh/schemas/native-artifacts-v1.json"
	canonicalRepository = "https://github.com/hopmesh/monorepo"
	canonicalBuilder    = "hopmesh/monorepo"
	canonicalWorkflow   = ".github/workflows/native-artifacts.yml"
	releaseRepository   = "hopmesh/hop-sdk-go"
	maxManifestBytes    = 10 << 20
	maxSignatureBytes   = 1 << 20
	maxArchiveFiles     = 20_000
	maxExpandedBytes    = int64(4 << 30)
)

var (
	versionPattern  = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
	shaPattern      = regexp.MustCompile(`^[0-9a-f]{40}$`)
	sha256Pattern   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	targetPattern   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:+-]*$`)
	filenamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]*\.(?:tar\.gz|zip)$`)
)

//go:embed native-artifacts-public.pem
var embeddedPublicKey []byte

type manifest struct {
	Schema     string     `json:"schema"`
	Version    string     `json:"version"`
	Tag        string     `json:"tag"`
	Repository string     `json:"repository"`
	SourceSHA  string     `json:"source_sha"`
	Builder    builder    `json:"builder"`
	Artifacts  []artifact `json:"artifacts"`
}

type builder struct {
	Repository string `json:"repository"`
	Workflow   string `json:"workflow"`
	RunID      int64  `json:"run_id"`
	RunAttempt int64  `json:"run_attempt"`
	Identity   string `json:"identity"`
}

type artifact struct {
	Target   string          `json:"target"`
	Filename string          `json:"filename"`
	SHA256   string          `json:"sha256"`
	Size     int64           `json:"size"`
	Archive  archiveManifest `json:"archive"`
}

type archiveManifest struct {
	Format string        `json:"format"`
	Files  []archiveFile `json:"files"`
}

type archiveFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Mode   string `json:"mode"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "libhop install rejected:", err)
		os.Exit(1)
	}
}

func run() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("resolve home directory: %w", err)
	}
	defaultPrefix := filepath.Join(home, ".local", "hop")
	version := flag.String("version", currentVersion, "exact release tag")
	target := flag.String("target", hostTarget(), "exact native target")
	prefix := flag.String("prefix", defaultPrefix, "stable installation prefix")
	bundle := flag.String("bundle", "", "local release bundle instead of network download")
	sourceSHA := flag.String("source-sha", "", "required canonical source SHA")
	publicKeyPath := flag.String("public-key", "", "test-only public key override for a local bundle")
	flag.Parse()

	if !versionPattern.MatchString(*version) {
		return fmt.Errorf("version must be an exact vX.Y.Z tag")
	}
	if *target != hostTarget() {
		return fmt.Errorf("target %q does not match this host %q", *target, hostTarget())
	}
	if *sourceSHA != "" && !shaPattern.MatchString(*sourceSHA) {
		return fmt.Errorf("source SHA must be 40 lowercase hexadecimal characters")
	}
	if *publicKeyPath != "" && *bundle == "" {
		return fmt.Errorf("a public-key override is allowed only with a local bundle")
	}

	work, err := os.MkdirTemp("", "hop-libhop-install-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)

	bundleDir := *bundle
	if bundleDir == "" {
		bundleDir = filepath.Join(work, "release")
		if err := os.Mkdir(bundleDir, 0o700); err != nil {
			return err
		}
		base := fmt.Sprintf("https://github.com/%s/releases/download/%s", releaseRepository, *version)
		if err := download(base+"/native-artifacts.json", filepath.Join(bundleDir, "native-artifacts.json"), maxManifestBytes); err != nil {
			return err
		}
		if err := download(base+"/native-artifacts.json.sig", filepath.Join(bundleDir, "native-artifacts.json.sig"), maxSignatureBytes); err != nil {
			return err
		}
	}

	manifestPath := filepath.Join(bundleDir, "native-artifacts.json")
	signaturePath := filepath.Join(bundleDir, "native-artifacts.json.sig")
	manifestBytes, err := readLimited(manifestPath, maxManifestBytes)
	if err != nil {
		return fmt.Errorf("read native manifest: %w", err)
	}
	signature, err := readLimited(signaturePath, maxSignatureBytes)
	if err != nil {
		return fmt.Errorf("read native manifest signature: %w", err)
	}
	publicKey := embeddedPublicKey
	if *publicKeyPath != "" {
		publicKey, err = os.ReadFile(*publicKeyPath)
		if err != nil {
			return fmt.Errorf("read public key: %w", err)
		}
	}
	if err := verifySignature(manifestBytes, signature, publicKey); err != nil {
		return err
	}
	value, err := parseManifest(manifestBytes)
	if err != nil {
		return err
	}
	if err := validateManifest(value, *version, *sourceSHA); err != nil {
		return err
	}
	selected, err := selectArtifact(value, *target)
	if err != nil {
		return err
	}
	archivePath := filepath.Join(bundleDir, selected.Filename)
	if *bundle == "" {
		base := fmt.Sprintf("https://github.com/%s/releases/download/%s", releaseRepository, *version)
		if err := download(base+"/"+url.PathEscape(selected.Filename), archivePath, selected.Size); err != nil {
			return err
		}
	}
	if err := verifyFile(archivePath, selected.Size, selected.SHA256); err != nil {
		return err
	}

	basePrefix, err := filepath.Abs(*prefix)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(basePrefix, 0o755); err != nil {
		return fmt.Errorf("create install prefix: %w", err)
	}
	staging, err := os.MkdirTemp(basePrefix, ".install-")
	if err != nil {
		return err
	}
	stagingOwned := true
	defer func() {
		if stagingOwned {
			_ = os.RemoveAll(staging)
		}
	}()
	if err := extractVerified(archivePath, selected, staging); err != nil {
		return err
	}
	if err := verifyInstalledShape(staging); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		library := filepath.Join(staging, "lib", "libhop.dylib")
		if output, err := exec.Command("install_name_tool", "-id", "@rpath/libhop.dylib", library).CombinedOutput(); err != nil {
			return fmt.Errorf("normalize dylib install name: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}
	installRoot := filepath.Join(basePrefix, *version)
	if err := writePkgConfig(staging, installRoot, strings.TrimPrefix(*version, "v")); err != nil {
		return err
	}
	marker, _ := json.MarshalIndent(map[string]string{
		"artifact_sha256": selected.SHA256,
		"source_sha":      value.SourceSHA,
		"target":          selected.Target,
		"version":         *version,
	}, "", "  ")
	marker = append(marker, '\n')
	if err := os.WriteFile(filepath.Join(staging, ".hop-libhop-install.json"), marker, 0o644); err != nil {
		return err
	}
	if err := replaceOwnedInstall(staging, installRoot); err != nil {
		return err
	}
	stagingOwned = false

	fmt.Printf("installed signed %s for %s\n", selected.Filename, selected.Target)
	fmt.Printf("verified source SHA %s and artifact SHA-256 %s\n", value.SourceSHA, selected.SHA256)
	fmt.Printf("export HOP_PREFIX=%s\n", shellQuote(installRoot))
	fmt.Println(`export PKG_CONFIG_PATH="$HOP_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"`)
	loader := "LD_LIBRARY_PATH"
	if runtime.GOOS == "darwin" {
		loader = "DYLD_LIBRARY_PATH"
	}
	fmt.Printf("export %s=\"$HOP_PREFIX/lib${%s:+:$%s}\"\n", loader, loader, loader)
	return nil
}

func hostTarget() string {
	arch := map[string]string{"amd64": "x86_64", "arm64": "aarch64"}[runtime.GOARCH]
	if arch == "" {
		return "unsupported-" + runtime.GOARCH
	}
	switch runtime.GOOS {
	case "darwin":
		return arch + "-apple-darwin"
	case "linux":
		return arch + "-unknown-linux-gnu"
	default:
		return "unsupported-" + runtime.GOOS
	}
}

func download(rawURL, destination string, limit int64) error {
	client := &http.Client{
		Timeout: 2 * time.Minute,
		CheckRedirect: func(request *http.Request, _ []*http.Request) error {
			if !allowedDownloadURL(request.URL) {
				return fmt.Errorf("release download redirected to unexpected URL %s", request.URL)
			}
			return nil
		},
	}
	request, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "hop-sdk-go-installer/1")
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("download %s: %w", rawURL, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || !allowedDownloadURL(response.Request.URL) {
		return fmt.Errorf("download %s returned HTTP %d", rawURL, response.StatusCode)
	}
	if response.ContentLength > limit {
		return fmt.Errorf("download exceeds signed size limit")
	}
	file, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	written, copyErr := io.Copy(file, io.LimitReader(response.Body, limit+1))
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if written > limit {
		return fmt.Errorf("download exceeds signed size limit")
	}
	return nil
}

func allowedDownloadURL(value *url.URL) bool {
	if value == nil || value.Scheme != "https" {
		return false
	}
	switch value.Hostname() {
	case "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com":
		return true
	default:
		return false
	}
}

func readLimited(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("file exceeds size limit: %s", path)
	}
	return data, nil
}

func verifySignature(value, signature, publicPEM []byte) error {
	block, rest := pem.Decode(publicPEM)
	if block == nil || len(strings.TrimSpace(string(rest))) != 0 {
		return fmt.Errorf("trusted manifest public key is invalid")
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return fmt.Errorf("parse trusted manifest public key: %w", err)
	}
	publicKey, ok := parsed.(*rsa.PublicKey)
	if !ok {
		return fmt.Errorf("trusted manifest key is not RSA")
	}
	digest := sha256.Sum256(value)
	if err := rsa.VerifyPKCS1v15(publicKey, crypto.SHA256, digest[:], signature); err != nil {
		return fmt.Errorf("detached native manifest signature is invalid")
	}
	return nil
}

func parseManifest(value []byte) (manifest, error) {
	var result manifest
	decoder := json.NewDecoder(strings.NewReader(string(value)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return result, fmt.Errorf("decode native manifest: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return result, fmt.Errorf("native manifest has trailing data")
	}
	return result, nil
}

func validateManifest(value manifest, version, sourceSHA string) error {
	if value.Schema != manifestSchema || value.Tag != version || value.Version != strings.TrimPrefix(version, "v") {
		return fmt.Errorf("manifest schema or version does not match %s", version)
	}
	if value.Repository != canonicalRepository || !shaPattern.MatchString(value.SourceSHA) {
		return fmt.Errorf("manifest repository or source SHA is invalid")
	}
	if sourceSHA != "" && value.SourceSHA != sourceSHA {
		return fmt.Errorf("manifest source SHA does not match the required source")
	}
	if value.Builder.Repository != canonicalBuilder || value.Builder.Workflow != canonicalWorkflow ||
		value.Builder.RunID < 1 || value.Builder.RunAttempt < 1 ||
		value.Builder.Identity != fmt.Sprintf("https://github.com/%s/actions/runs/%d", canonicalBuilder, value.Builder.RunID) {
		return fmt.Errorf("manifest builder attestation is invalid")
	}
	if len(value.Artifacts) == 0 {
		return fmt.Errorf("manifest contains no artifacts")
	}
	targets := make(map[string]bool)
	filenames := make(map[string]bool)
	for _, artifact := range value.Artifacts {
		if !targetPattern.MatchString(artifact.Target) || targets[artifact.Target] {
			return fmt.Errorf("manifest artifact target is invalid or duplicated")
		}
		targets[artifact.Target] = true
		if !filenamePattern.MatchString(artifact.Filename) || filenames[artifact.Filename] ||
			pathpkg.Base(artifact.Filename) != artifact.Filename {
			return fmt.Errorf("manifest artifact filename is invalid or duplicated")
		}
		filenames[artifact.Filename] = true
		validFormat := artifact.Archive.Format == "tar.gz" || artifact.Archive.Format == "zip"
		if artifact.Size < 1 || !sha256Pattern.MatchString(artifact.SHA256) || !validFormat ||
			!strings.HasSuffix(artifact.Filename, "."+artifact.Archive.Format) {
			return fmt.Errorf("manifest artifact size, digest, or archive format is invalid")
		}
		if len(artifact.Archive.Files) == 0 || len(artifact.Archive.Files) > maxArchiveFiles {
			return fmt.Errorf("manifest archive inventory is empty or oversized")
		}
		paths := make(map[string]bool)
		for _, file := range artifact.Archive.Files {
			if err := validateArchivePath(file.Path); err != nil || paths[file.Path] || file.Size < 0 ||
				!sha256Pattern.MatchString(file.SHA256) || (file.Mode != "0644" && file.Mode != "0755") {
				return fmt.Errorf("manifest archive entry is invalid or duplicated: %q", file.Path)
			}
			paths[file.Path] = true
		}
	}
	return nil
}

func selectArtifact(value manifest, target string) (artifact, error) {
	var selected artifact
	matches := 0
	for _, candidate := range value.Artifacts {
		if candidate.Target == target {
			selected = candidate
			matches++
		}
	}
	if matches != 1 {
		return selected, fmt.Errorf("target must resolve to exactly one artifact: %q", target)
	}
	return selected, nil
}

func validateArchivePath(value string) error {
	if value == "" || strings.ContainsAny(value, "\\\x00") || strings.HasPrefix(value, "/") ||
		pathpkg.Clean(value) != value {
		return fmt.Errorf("unsafe archive path")
	}
	for _, part := range strings.Split(value, "/") {
		if part == "" || part == "." || part == ".." {
			return fmt.Errorf("unsafe archive path")
		}
	}
	return nil
}

func verifyFile(path string, size int64, expectedDigest string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("native artifact is missing: %w", err)
	}
	if !info.Mode().IsRegular() || info.Size() != size {
		return fmt.Errorf("native artifact size or file type is invalid")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return err
	}
	if hex.EncodeToString(digest.Sum(nil)) != expectedDigest {
		return fmt.Errorf("native artifact SHA-256 mismatch")
	}
	return nil
}

func extractVerified(archivePath string, selected artifact, destination string) error {
	if selected.Archive.Format != "tar.gz" {
		return fmt.Errorf("host libhop artifact must be a tar.gz archive")
	}
	expected := make(map[string]archiveFile, len(selected.Archive.Files))
	for _, file := range selected.Archive.Files {
		expected[file.Path] = file
	}
	archive, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer archive.Close()
	compressed, err := gzip.NewReader(archive)
	if err != nil {
		return fmt.Errorf("open native archive: %w", err)
	}
	defer compressed.Close()
	reader := tar.NewReader(compressed)
	seen := make(map[string]bool)
	var expanded int64
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read native archive: %w", err)
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			return fmt.Errorf("native archive contains a non-file entry: %q", header.Name)
		}
		if err := validateArchivePath(header.Name); err != nil || seen[header.Name] {
			return fmt.Errorf("native archive path is unsafe or duplicated: %q", header.Name)
		}
		entry, ok := expected[header.Name]
		if !ok || header.Size != entry.Size {
			return fmt.Errorf("native archive inventory mismatch: %q", header.Name)
		}
		mode := "0644"
		if header.Mode&0o111 != 0 {
			mode = "0755"
		}
		if mode != entry.Mode {
			return fmt.Errorf("native archive mode mismatch: %q", header.Name)
		}
		expanded += header.Size
		if expanded > maxExpandedBytes {
			return fmt.Errorf("native archive expands beyond the size limit")
		}
		target := filepath.Join(destination, filepath.FromSlash(header.Name))
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return err
		}
		digest := sha256.New()
		written, copyErr := io.Copy(io.MultiWriter(file, digest), reader)
		closeErr := file.Close()
		if copyErr != nil || closeErr != nil || written != entry.Size {
			return fmt.Errorf("extract native archive entry %q", header.Name)
		}
		if hex.EncodeToString(digest.Sum(nil)) != entry.SHA256 {
			return fmt.Errorf("native archive entry digest mismatch: %q", header.Name)
		}
		permissions := os.FileMode(0o644)
		if entry.Mode == "0755" {
			permissions = 0o755
		}
		if err := os.Chmod(target, permissions); err != nil {
			return err
		}
		seen[header.Name] = true
	}
	if len(seen) != len(expected) {
		return fmt.Errorf("native archive omitted signed inventory entries")
	}
	return nil
}

func verifyInstalledShape(root string) error {
	library := "libhop.so"
	if runtime.GOOS == "darwin" {
		library = "libhop.dylib"
	}
	required := []string{filepath.Join(root, "include", "hop.h"), filepath.Join(root, "lib", library)}
	for _, path := range required {
		if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("release archive is missing %s", filepath.Base(path))
		}
	}
	header, err := os.ReadFile(required[0])
	if err != nil {
		return err
	}
	if !strings.Contains(string(header), "#define HOP_ABI_VERSION 4") {
		return fmt.Errorf("release header does not declare the expected ABI version")
	}
	entries := 0
	err = filepath.WalkDir(root, func(_ string, entry os.DirEntry, walkErr error) error {
		if walkErr == nil && !entry.IsDir() {
			entries++
		}
		return walkErr
	})
	if err != nil || entries != 2 {
		return fmt.Errorf("release archive must contain exactly hop.h and one host library")
	}
	return nil
}

func writePkgConfig(staging, installRoot, version string) error {
	directory := filepath.Join(staging, "lib", "pkgconfig")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	prefix := strings.NewReplacer("\\", "\\\\", " ", "\\ ").Replace(installRoot)
	value := fmt.Sprintf(`prefix=%s
exec_prefix=${prefix}
libdir=${prefix}/lib
includedir=${prefix}/include

Name: hop
Description: Hop protocol core C ABI
Version: %s
Libs: -L${libdir} -lhop -Wl,-rpath,${libdir}
Cflags: -I${includedir}
`, prefix, version)
	return os.WriteFile(filepath.Join(directory, "hop.pc"), []byte(value), 0o644)
}

func replaceOwnedInstall(staging, destination string) error {
	if _, err := os.Stat(destination); err == nil {
		if _, markerErr := os.Stat(filepath.Join(destination, ".hop-libhop-install.json")); markerErr != nil {
			return fmt.Errorf("refusing to replace an installation without the Hop ownership marker: %s", destination)
		}
		backup := destination + ".previous"
		_ = os.RemoveAll(backup)
		if err := os.Rename(destination, backup); err != nil {
			return err
		}
		if err := os.Rename(staging, destination); err != nil {
			_ = os.Rename(backup, destination)
			return err
		}
		return os.RemoveAll(backup)
	} else if !os.IsNotExist(err) {
		return err
	}
	return os.Rename(staging, destination)
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'"
}
