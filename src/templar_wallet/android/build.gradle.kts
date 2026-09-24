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
}
subprojects {
    project.evaluationDependsOn(":app")
    // Flutter's embedding pulls androidx.window, which demands compileSdk 33+;
    // some plugins (biometric_storage) still declare 31 and fail the AGP
    // dependency check. Raise every plugin module to the app's compileSdk.
    // (:app itself is already evaluated by the line above — and needs nothing.)
    if (project.state.executed) return@subprojects
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        val target = 36
        val setters = listOf("setCompileSdk" to Integer::class.java, "compileSdkVersion" to Int::class.javaPrimitiveType!!)
        for ((name, type) in setters) {
            try {
                android.javaClass.getMethod(name, type).invoke(android, target)
                break
            } catch (_: NoSuchMethodException) {
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
