import java.io.File
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.api.tasks.bundling.Jar
import org.gradle.api.tasks.bundling.Zip
import org.gradle.plugins.signing.Sign

// Hop Kotlin SDK. JVM tests exercise the JNA wrapper against a host libhop. The publication is an
// Android AAR with classes.jar, one libhop.so per supported ABI, and Prefab metadata/header content.
plugins {
    kotlin("jvm") version "2.4.0"
    application
    jacoco
    `maven-publish`
    signing
}

group = "sh.hop"
version = "0.0.1"

repositories { mavenCentral() }

dependencies {
    implementation("net.java.dev.jna:jna:5.19.1")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    systemProperty(
        "jna.library.path",
        System.getenv("HOP_LIBDIR")
            ?: layout.projectDirectory.dir("../../target/debug").asFile.absolutePath,
    )
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
                url.set("https://github.com/hopmesh/hop-sdk-android")
                licenses {
                    license {
                        name.set("Apache License, Version 2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                    }
                }
                scm {
                    connection.set("scm:git:https://github.com/hopmesh/hop-sdk-android.git")
                    developerConnection.set("scm:git:ssh://git@github.com/hopmesh/hop-sdk-android.git")
                    url.set("https://github.com/hopmesh/hop-sdk-android")
                    tag.set("v${project.version}")
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
