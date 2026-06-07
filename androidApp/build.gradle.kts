import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    id("com.android.application")
    kotlin("android")
    kotlin("plugin.compose")
}

val releaseSigningFile = file("signing.properties")
val releaseSigning = Properties().apply {
    if (releaseSigningFile.isFile) {
        releaseSigningFile.inputStream().use(::load)
    }
}

android {
    namespace = "com.vkturnproxy.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.vkturnproxy.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 164
        versionName = "1.0"
    }

    signingConfigs {
        if (releaseSigningFile.isFile) {
            create("release") {
                storeFile = file(requireNotNull(releaseSigning.getProperty("storeFile")) {
                    "androidApp/signing.properties missing storeFile"
                })
                storePassword = requireNotNull(releaseSigning.getProperty("storePassword")) {
                    "androidApp/signing.properties missing storePassword"
                }
                keyAlias = requireNotNull(releaseSigning.getProperty("keyAlias")) {
                    "androidApp/signing.properties missing keyAlias"
                }
                keyPassword = requireNotNull(releaseSigning.getProperty("keyPassword")) {
                    "androidApp/signing.properties missing keyPassword"
                }
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    buildFeatures {
        compose = true
    }

    lint {
        checkReleaseBuilds = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}

dependencies {
    implementation(project(":shared"))
    implementation(files("libs/vkturnbridge.aar"))
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation:1.11.2")
    implementation("androidx.compose.runtime:runtime:1.11.2")
    implementation("androidx.compose.ui:ui:1.11.2")
    implementation("androidx.compose.ui:ui-tooling-preview:1.11.2")
    debugImplementation("androidx.compose.ui:ui-tooling:1.11.2")
}
