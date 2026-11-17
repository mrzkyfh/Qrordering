allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Paksa plugin yg masih pakai compileSdk lama (mis. bluetooth_print_plus = 31)
    // agar minimal 35 — sebagian dependency androidx butuh compileSdk >= 33/34.
    // Didaftarkan di sini (sebelum evaluationDependsOn memicu evaluasi).
    // Hanya menaikkan yg < 35; modul yg sudah 35/36 (mis. :app) tidak disentuh.
    afterEvaluate {
        extensions.findByName("android")?.withGroovyBuilder {
            val current = ("getCompileSdkVersion"() as String?)
                ?.removePrefix("android-")?.toIntOrNull() ?: 0
            if (current in 1..34) {
                "compileSdkVersion"(35)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
