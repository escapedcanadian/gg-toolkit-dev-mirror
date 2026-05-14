pluginManagement {
    repositories {
        mavenLocal()
        gradlePluginPortal()
        mavenCentral()
        maven {
            name = "GridGain External Repository"
            url = uri("https://maven.gridgain.com/nexus/content/repositories/external")
        }
    }
}

// Use the local plugin build directly to avoid publishing to mavenLocal during development
includeBuild("../gridgain-demo-gradle-plugin"){
    dependencySubstitution {
        substitute(module("com.gridgain.demo:gridgain-demo-gradle-plugin"))
            .using(project(":"))
    }
}

// Include the UI project so `launchPluginUi` can find it on the classpath
includeBuild("../gridgain-demo-ui") {
    dependencySubstitution {
        substitute(module("com.gridgain.demo:gridgain-demo-ui"))
            .using(project(":"))
    }
}

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.8.0"
    id("com.gradle.enterprise") version "3.16"
}

// Disable build scan to reduce noise
// gradleEnterprise {
//     buildScan {
//         termsOfServiceUrl = "https://gradle.com/terms-of-service"
//         termsOfServiceAgree = "yes"
//     }
// }

rootProject.name = "gridgain-demo-toolkit-dev"
