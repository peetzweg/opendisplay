#ifndef LOG_SINK_H
#define LOG_SINK_H

#include <android/log.h>
#include <jni.h>
#include <cstdarg>
#include <cstdio>

#define LOG_SINK_TAG "AirPlayNative"

/*
 * log sink writing to both app log UI and logcat. any thread may emit, but emitting can
 * be slow (JNI call)
 */
class LogSink {
public:
    // bind to Kotlin handler with `void onLog(String)` (bridge.LogListener)
    bool bind(JNIEnv *env, jobject handler) {
        bool ok = true;
        if (env->GetJavaVM(&mVm) != JNI_OK) {
            ok = false;
        }
        mObj = env->NewGlobalRef(handler);
        if (!mObj) {
            ok = false;
        }
        jclass cls = env->GetObjectClass(handler);
        if (!cls) {
            ok = false;
        } else {
            mMethod = env->GetMethodID(cls, "onLog", "(Ljava/lang/String;)V");
            if (!mMethod) ok = false;
            env->DeleteLocalRef(cls);
        }
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
        if (!ok) {
            if (mObj) {
                env->DeleteGlobalRef(mObj);
                mObj = nullptr;
            }
            mMethod = nullptr;
            mVm = nullptr;
        }
        return ok;
    }

    // releases handler global ref; thread safe
    ~LogSink() {
        if (!mVm || !mObj) return;
        JNIEnv *env = nullptr;
        bool attached = false;
        if (mVm->GetEnv((void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
            if (mVm->AttachCurrentThread(&env, nullptr) != JNI_OK) return;
            attached = true;
        }
        env->DeleteGlobalRef(mObj);
        if (attached) mVm->DetachCurrentThread();
    }

    // log level only affects logcat, UI ignores it
    void info(const char *fmt, ...)  __attribute__((format(printf, 2, 3))) {
        va_list ap; va_start(ap, fmt); vemit(ANDROID_LOG_INFO, fmt, ap); va_end(ap);
    }
    void warn(const char *fmt, ...)  __attribute__((format(printf, 2, 3))) {
        va_list ap; va_start(ap, fmt); vemit(ANDROID_LOG_WARN, fmt, ap); va_end(ap);
    }
    void error(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
        va_list ap; va_start(ap, fmt); vemit(ANDROID_LOG_ERROR, fmt, ap); va_end(ap);
    }

private:
    void vemit(int prio, const char *fmt, va_list ap) {
        char buf[256];
        vsnprintf(buf, sizeof(buf), fmt, ap);
        __android_log_print(prio, LOG_SINK_TAG, "%s", buf);
        if (!mVm || !mObj || !mMethod) return;

        JNIEnv *env = nullptr;
        bool attached = false;
        if (mVm->GetEnv((void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
            if (mVm->AttachCurrentThread(&env, nullptr) != JNI_OK) return;
            attached = true;
        }
        jstring s = env->NewStringUTF(buf);
        if (!s) {
            if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
        } else {
            env->CallVoidMethod(mObj, mMethod, s);
            if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
            env->DeleteLocalRef(s);
        }
        if (attached) mVm->DetachCurrentThread();
    }

    JavaVM *mVm = nullptr;
    jobject mObj = nullptr;      // global ref to JNI handler
    jmethodID mMethod = nullptr; // onLog(String)
};

#endif  // LOG_SINK_H
