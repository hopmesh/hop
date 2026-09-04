import java.io.File
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.api.tasks.bundling.Jar
import org.gradle.api.tasks.bundling.Zip
import org.gradle.plugins.signing.Sign

// Hop Kotlin SDK. JVM tests exercise the JNA wrapper against a host libhop. The publication is an
// Android AAR with classes.jar, one libhop.so per supported ABI, and Prefab metadata/header content.
plugins {
    // 2.2.10, deliberately BELOW the Kotlin of the other Android builds in this repo. This build
    // PUBLISHES sh.hop:hop, and a published library must carry Kotlin metadata the OLDEST consumer
    // can read: a newer compiler always reads older metadata, never the reverse. The floor is set by
    // the React Native 0.87 app (apps/react-native/HopDemo), whose Kotlin the app does not choose
    // itself: its versionless root classpath resolves kotlin-gradle-plugin by conflict resolution to
    // 2.2.10 (AGP 9.2.1's transitive pin, which beats React Native's own 2.2.0), so 2.2.x is what
    // compiles against this AAR and metadata 2.2.0 is the most this SDK may emit. Every other
    // consumer (apps/android, bearers/android, the export-smoke consumer) is on 2.4.x and reads 2.2.0
    // metadata fine. The bearers/apps ":hop-sdk" shims compile this module's SOURCES with their own
    // 2.4.10 pins, so this number changes only the published AAR's metadata, not their builds. Bump
    // this only in lockstep with the oldest consumer's compiler floor.
    kotlin("jvm") version "2.2.10"
    application
    jacoco
    `maven-publish`
    signing
}

group = "sh.hop"
version = "0.0.5"

repositories { mavenCentral() }

dependencies {
    implementation("net.java.dev.jna:jna:5.19.1")
    testImplementation(kotlin("test"))
}

val buildHopNative by tasks.registering(Exec::class) {
    val rootDir = layout.projectDirectory.dir("../..").asFile
    workingDir = rootDir
    val cargoBin = File(System.getProperty("user.home"), ".cargo/bin")
    val currentPath = System.getenv("PATH") ?: ""
    val newPath = if (cargoBin.exists()) "${cargoBin.absolutePath}:${currentPath}" else currentPath
    environment("PATH", newPath)
    val sqlcipher = System.getenv("HOP_SQLCIPHER") ?: "1"
    if (sqlcipher == "1") {
        commandLine("cargo", "build", "-p", "hop", "--no-default-features", "--features", "sqlcipher")
    } else {
        commandLine("cargo", "build", "-p", "hop")
    }
}

tasks.test {
    val libDir = System.getenv("HOP_LIBDIR")
        ?: layout.projectDirectory.dir("../../target/debug").asFile.absolutePath
    val dylib = File(libDir, "libhop.dylib")
    val so = File(libDir, "libhop.so")
    if (!dylib.exists() && !so.exists() && System.getenv("HOP_SKIP_NATIVE_BUILD") == null) {
        dependsOn(buildHopNative)
    }
    useJUnitPlatform()
    systemProperty("jna.library.path", libDir)
    finalizedBy(tasks.named("jacocoTestReport"))
}

val smokeCoverageExcludes = listOf("sh/hop/SmokeKt.class", "sh/hop/Smoke*.class", "sh/hop/LoopbackBearer*.class")

tasks.named<JacocoReport>("jacocoTestReport") {
    dependsOn(tasks.test)
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
    classDirectories.setFrom(
        files(classDirectories.files.map { fileTree(it) { exclude(smokeCoverageExcludes) } }),
    )
}

tasks.named<JacocoCoverageVerification>("jacocoTestCoverageVerification") {
    dependsOn(tasks.test)
    classDirectories.setFrom(
        files(classDirectories.files.map { fileTree(it) { exclude(smokeCoverageExcludes) } }),
    )
    violationRules {
        rule {
            limit {
                counter = "LINE"
                value = "COVEREDRATIO"
                minimum = "0.80".toBigDecimal()
            }
        }
    }
}

application {
    mainClass.set("sh.hop.SmokeKt")
}

tasks.named<JavaExec>("run") {
    System.getenv("HOP_LIBDIR")?.let { systemProperty("jna.library.path", it) }
}

kotlin { jvmToolchain(17) }

val androidAbis = listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
val hopNativeDir = providers.gradleProperty("hopNativeDir")
    .map { file(it) }
    .orElse(layout.projectDirectory.dir("native/android").asFile)
val aarMetadataDir = layout.buildDirectory.dir("generated/aar-metadata")

val prepareAarMetadata by tasks.registering {
    outputs.dir(aarMetadataDir)
    doLast {
        val root = aarMetadataDir.get().asFile
        root.deleteRecursively()
        root.mkdirs()
        root.resolve("prefab.json").writeText(
            """{"name":"hop","schema_version":2,"version":"${project.version}"}""" + "\n",
        )
        val module = root.resolve("modules/libhop")
        module.mkdirs()
        module.resolve("module.json").writeText(
            """{"export_libraries":[],"library_name":"libhop"}""" + "\n",
        )
        androidAbis.forEach { abi ->
            val abiDir = module.resolve("libs/android.$abi")
            abiDir.mkdirs()
            abiDir.resolve("abi.json").writeText(
                """{"abi":"$abi","api":23,"ndk":26,"stl":"none","static":false}""" + "\n",
            )
        }
    }
}

val sourcesJar by tasks.registering(Jar::class) {
    archiveClassifier.set("sources")
    from(sourceSets.main.get().allSource)
}

val docsJar by tasks.registering(Jar::class) {
    archiveClassifier.set("javadoc")
    from("README.md", "LICENSE.md")
}

val hopAar by tasks.registering(Zip::class) {
    dependsOn(tasks.named("jar"), prepareAarMetadata)
    archiveBaseName.set("hop")
    archiveVersion.set(project.version.toString())
    archiveExtension.set("aar")
    destinationDirectory.set(layout.buildDirectory.dir("distributions"))
    isReproducibleFileOrder = true
    isPreserveFileTimestamps = false

    from(tasks.named<Jar>("jar").flatMap { it.archiveFile }) {
        rename { "classes.jar" }
    }
    from("src/main/AndroidManifest.xml")
    from(aarMetadataDir) { into("prefab") }
    from("include/hop.h") { into("prefab/modules/libhop/include") }
    androidAbis.forEach { abi ->
        from(hopNativeDir.map { it.resolve("$abi/libhop.so") }) {
            into("jni/$abi")
        }
        from(hopNativeDir.map { it.resolve("$abi/libhop.so") }) {
            into("prefab/modules/libhop/libs/android.$abi")
        }
    }
    doFirst {
        val root = hopNativeDir.get()
        val missing = androidAbis.map { root.resolve("$it/libhop.so") }.filterNot(File::isFile)
        require(missing.isEmpty()) { "missing verified Android libhop slices: $missing" }
        require(file("include/hop.h").isFile) { "include/hop.h is required for Prefab" }
    }
}

val hopMavenRepository = providers.gradleProperty("hopMavenRepository")
    .orElse(layout.buildDirectory.dir("maven-repository").map { it.asFile.absolutePath })

publishing {
    publications {
        create<MavenPublication>("hop") {
            groupId = "sh.hop"
            artifactId = "hop"
            version = project.version.toString()
            artifact(hopAar)
            artifact(sourcesJar)
            artifact(docsJar)
            pom {
                name.set("Hop for Android")
                description.set("Hop mesh client SDK for Android, including libhop native ABI slices.")
                url.set("https://hopme.sh")
                licenses {
                    license {
                        name.set("Apache License, Version 2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                    }
                }
                developers {
                    developer {
                        id.set("hopmesh")
                        name.set("Hop Mesh, LLC")
                        url.set("https://hopme.sh")
                    }
                }
                withXml {
                    val dependencies = asNode().appendNode("dependencies")
                    val dependency = dependencies.appendNode("dependency")
                    dependency.appendNode("groupId", "net.java.dev.jna")
                    dependency.appendNode("artifactId", "jna")
                    dependency.appendNode("version", "5.19.1")
                    dependency.appendNode("type", "aar")
                    dependency.appendNode("scope", "runtime")
                }
            }
        }
    }
    repositories {
        maven {
            name = "hop"
            url = uri(hopMavenRepository.get())
            if (hopMavenRepository.get().startsWith("https://")) {
                credentials {
                    username = System.getenv("MAVEN_USERNAME") ?: ""
                    password = System.getenv("MAVEN_PASSWORD") ?: ""
                }
            }
        }
    }
}

val signingKey = System.getenv("MAVEN_SIGNING_KEY")
val signingPassword = System.getenv("MAVEN_SIGNING_PASSWORD")
signing {
    if (!signingKey.isNullOrBlank() && !signingPassword.isNullOrBlank()) {
        useInMemoryPgpKeys(signingKey, signingPassword)
        sign(publishing.publications.named("hop").get())
    }
}
tasks.withType<Sign>().configureEach {
    onlyIf { !signingKey.isNullOrBlank() && !signingPassword.isNullOrBlank() }
}
