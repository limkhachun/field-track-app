plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.field_track_app"
    compileSdk = flutter.compileSdkVersion
    
    // 🟢 建议明确指定 NDK 版本，或者直接使用 flutter.ndkVersion
    // 如果遇到 NDK 报错，可以尝试取消下面这行的注释并指定具体版本，例如 "25.1.8937393"
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // 🟢 1. 开启核心库脱糖 (Fix for flutter_local_notifications & older Android versions)
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.field_track_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // 🟢 2. 确保开启 MultiDex
        multiDexEnabled = true 
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            
            // 🟢 3. 生产环境优化配置
            // 开启代码混淆/压缩
            isMinifyEnabled = true 
            // 开启资源压缩 (移除未使用的图片等)
            isShrinkResources = true 
            // 引用混淆规则文件 (默认规则 + 自定义规则)
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

// 🟢 4. 添加依赖
dependencies {
    // 核心库脱糖依赖 (必须与上面的 isCoreLibraryDesugaringEnabled = true 配合使用)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    
    // 如果需要手动添加 multidex 依赖（通常 compileSdk 34+ 不需要显式添加，但加上无害）
    implementation("androidx.multidex:multidex:2.0.1")
}