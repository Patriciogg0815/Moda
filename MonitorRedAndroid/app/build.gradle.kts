plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("io.github.takahirom.roborazzi")
}

// La versión sale del número de ejecución de GitHub Actions (1.0.N), igual que las apps de Windows
val buildNumber = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()

android {
    namespace = "lat.garridoitsolutions.monitorred"
    compileSdk = 36

    defaultConfig {
        applicationId = "lat.garridoitsolutions.monitorred"
        minSdk = 26
        targetSdk = 36
        versionCode = buildNumber
        versionName = "1.0.$buildNumber"
    }

    // Firma para Google Play: solo si GitHub tiene los secretos de la clave de subida (ver README.md).
    // Sin ellos, el .aab sale sin firmar y se firma en la PC.
    val keystorePath = System.getenv("MONITORRED_KEYSTORE")
    signingConfigs {
        // Clave de PRUEBA, pública a propósito: así cada APK de prueba se instala encima del anterior.
        // No sirve para Google Play (Play usa la clave de subida de abajo).
        getByName("debug") {
            storeFile = file("prueba.keystore")
            storePassword = "android"
            keyAlias = "prueba"
            keyPassword = "android"
        }
        if (keystorePath != null && file(keystorePath).exists()) {
            create("subida") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("MONITORRED_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MONITORRED_KEY_ALIAS")
                keyPassword = System.getenv("MONITORRED_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfigs.findByName("subida")?.let { signingConfig = it }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            // Para compilar en una red que limita Maven Central: -ProbolectricRepo=<espejo>
            val repo = providers.gradleProperty("robolectricRepo").orNull
            all { if (repo != null) it.systemProperty("robolectric.dependency.repo.url", repo) }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.12.00")
    implementation(composeBom)
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("androidx.work:work-runtime-ktx:2.10.5")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.77.0")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.77.0")
    testImplementation(composeBom)
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
