/* Scrup - Android CPython embedded driver (JNI).
 *
 * Empaqueta CPython como native library JNI dentro del APK. Android/SELinux
 * permite a una app (untrusted_app) cargar/ejecutar las libs nativas del APK
 * (jniLibs, etiquetadas apk_data_file) - a diferencia de un binario suelto en
 * app_data_file que queda bloqueado por execute_no_trans.
 *
 * Se usa la API C pública de Python (PyConfig / Py_InitializeFromConfig) para
 * ejecutar el intérprete embebido DENTRO del proceso de la app.
 */
#include <jni.h>
#include <Python.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <android/log.h>

#define LOGTAG "ScrupPy"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOGTAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOGTAG, __VA_ARGS__)

static const char *g_pythonHome = NULL;
static const char *g_pythonPath = NULL;
static int g_initialized = 0;
static volatile int g_cancel = 0;

JNIEXPORT void JNICALL
Java_com_scrup_scrup_MainActivity_pythonConfigure(
        JNIEnv *env, jobject thiz,
        jstring home, jstring pythonpath)
{
    const char *h = (*env)->GetStringUTFChars(env, home, NULL);
    const char *pp = (*env)->GetStringUTFChars(env, pythonpath, NULL);
    if (g_pythonHome) free((void *)g_pythonHome);
    if (g_pythonPath) free((void *)g_pythonPath);
    g_pythonHome = strdup(h);
    g_pythonPath = strdup(pp);
    (*env)->ReleaseStringUTFChars(env, home, h);
    (*env)->ReleaseStringUTFChars(env, pythonpath, pp);
    LOGI("configure home=%s path=%s", g_pythonHome, g_pythonPath);
}

static int py_init(void)
{
    if (g_initialized) return 0;

    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    if (g_pythonHome) {
        PyStatus st = PyConfig_SetBytesString(&config, &config.home, g_pythonHome);
        if (PyStatus_Exception(st)) {
            PyConfig_Clear(&config);
            LOGE("set home FAILED: %s", st.err_msg ? st.err_msg : "?");
            return -1;
        }
    }
    if (g_pythonPath) {
        PyStatus st = PyConfig_SetBytesString(&config, &config.pythonpath_env, g_pythonPath);
        if (PyStatus_Exception(st)) {
            PyConfig_Clear(&config);
            LOGE("set pythonpath FAILED: %s", st.err_msg ? st.err_msg : "?");
            return -1;
        }
    }

    config.safe_path = 1;
    config.install_signal_handlers = 0;
    config.parse_argv = 0;
    config.use_environment = 0;
    config.write_bytecode = 0;
    PyConfig_SetBytesString(&config, &config.program_name, "python3");

    /* PYTHONMALLOC=malloc: disable mimalloc/pymalloc to avoid reading
     * /proc/sys/vm/* (blocked by SELinux untrusted_app).
     * PYTHONUNBUFFERED: force unbuffered output so log is written
     * before sys.exit() closes the process. */
    setenv("PYTHONMALLOC", "malloc", 1);
    setenv("PYTHONUNBUFFERED", "1", 1);
    if (g_pythonHome) setenv("PYTHONHOME", g_pythonHome, 1);
    /* LD_LIBRARY_PATH to toolchain lib dir so dynamic modules
     * (_ssl, _hashlib, etc.) are found at runtime. */
    if (g_pythonHome) {
        char *ld = (char *)malloc(strlen(g_pythonHome) + 8);
        sprintf(ld, "%s/lib", g_pythonHome);
        setenv("LD_LIBRARY_PATH", ld, 1);
        free(ld);
    }
    /* Point OpenSSL to Android system CA certs. use_environment=0
     * prevents os.environ from calling putenv(), so we set it here
     * at the C level where getenv() can see it. */
    if (!getenv("SSL_CERT_DIR"))
        setenv("SSL_CERT_DIR", "/system/etc/security/cacerts", 1);

    PyStatus st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);

    if (PyStatus_Exception(st)) {
        LOGE("Py_InitializeFromConfig FAILED: %s (exitcode=%d)",
             st.err_msg ? st.err_msg : "?", st.exitcode);
        return -1;
    }
    g_initialized = 1;
    LOGI("python initialized OK");
    return 0;
}

JNIEXPORT jstring JNICALL
Java_com_scrup_scrup_MainActivity_pythonHello(JNIEnv *env, jobject thiz)
{
    if (py_init() != 0) {
        return (*env)->NewStringUTF(env, "PY_INIT_FAILED");
    }
    int rc = PyRun_SimpleString(
        "import sys\n"
        "out = 'hola desde python ' + sys.version.split()[0]\n");
    if (rc != 0) {
        PyErr_Print();
        return (*env)->NewStringUTF(env, "ERR_SCRIPT");
    }
    PyObject *main = PyImport_AddModule("__main__");
    PyObject *dict  = PyModule_GetDict(main);
    PyObject *out   = PyDict_GetItemString(dict, "out");
    const char *str = out ? PyUnicode_AsUTF8(out) : "sin salida";
    return (*env)->NewStringUTF(env, str ? str : "?");
}

/* Executes yt-dlp (a zipapp). script_path is the absolute path to the
 * wrapper script; args become sys.argv. Python stdout/stderr are
 * redirected to the log file so Kotlin can read the output. Returns
 * the exit code (0 = ok, !=0 = error). */
JNIEXPORT jint JNICALL
Java_com_scrup_scrup_MainActivity_pythonRunYtDlp(
        JNIEnv *env, jobject thiz,
        jstring script_path, jobjectArray args, jstring log_path)
{
    if (py_init() != 0) return 200;

    const char *script = (*env)->GetStringUTFChars(env, script_path, NULL);
    const char *logp   = (*env)->GetStringUTFChars(env, log_path, NULL);
    jsize nargs = (*env)->GetArrayLength(env, args);

    int exit_code = 1;
    g_cancel = 0;

    PyObject *sys = PyImport_ImportModule("sys");
    if (!sys) { PyErr_Print(); }
    else {
        /* sys.argv = [script, args...] */
        PyObject *argv = PyList_New(nargs + 1);
        PyList_SetItem(argv, 0, PyUnicode_FromString(script));
        for (jsize i = 0; i < nargs; i++) {
            jstring js = (jstring)(*env)->GetObjectArrayElement(env, args, i);
            const char *s = js ? (*env)->GetStringUTFChars(env, js, NULL) : NULL;
            PyList_SetItem(argv, i + 1, PyUnicode_FromString(s ? s : ""));
            if (js) (*env)->ReleaseStringUTFChars(env, js, s);
        }
        PyObject_SetAttrString(sys, "argv", argv);
        Py_DECREF(argv);

        /* Redirect Python sys.stdout/stderr to the log file. */
        char *setup = (char *)malloc(strlen(logp) + 300);
        sprintf(setup,
            "import sys\n"
            "_scrup_restore=(sys.stdout,sys.stderr)\n"
            "_scrup_logf=open('%s','w',buffering=1)\n"
            "sys.stdout=_scrup_logf\n"
            "sys.stderr=_scrup_logf\n",
            logp);
        int r2 = PyRun_SimpleString(setup);
        free(setup);
        if (r2 != 0) PyErr_Print();

        /* runpy.run_path(script) runs the wrapper/yt-dlp zipapp. */
        PyObject *runpy = PyImport_ImportModule("runpy");
        if (runpy) {
            PyObject *res = PyObject_CallMethod(runpy, "run_path", "s", script);
            if (res) {
                Py_DECREF(res);
                exit_code = 0;
            } else {
                if (!g_cancel) PyErr_Print();
                PyErr_Clear();
                exit_code = 1;
            }
            Py_DECREF(runpy);
        } else {
            PyErr_Print();
            PyErr_Clear();
            exit_code = 1;
        }

        /* Restore sys.stdout/stderr and flush/close the log file. */
        PyRun_SimpleString(
            "import sys\n"
            "if '_scrup_restore' in globals():\n"
            "  sys.stdout, sys.stderr = _scrup_restore\n"
            "  del _scrup_restore\n"
            "if '_scrup_logf' in globals():\n"
            "  _scrup_logf.flush(); _scrup_logf.close(); del _scrup_logf\n");
    }

    (*env)->ReleaseStringUTFChars(env, script_path, script);
    (*env)->ReleaseStringUTFChars(env, log_path, logp);
    return exit_code;
}

/* Requests interrupt (KeyboardInterrupt) to cancel an ongoing execution.
 * Must be called from ANOTHER thread. */
JNIEXPORT void JNICALL
Java_com_scrup_scrup_MainActivity_pythonCancel(JNIEnv *env, jobject thiz)
{
    g_cancel = 1;
    PyErr_SetInterrupt();
}
