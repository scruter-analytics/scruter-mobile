package net.scruter.internal

/** What `Scruter.start` was given (docs/MOBILE.md §3.1), plus what a wrapper SDK (React Native, Flutter) sets. */
internal class Options(
    val appId: String,
    val debugKey: String?,
    val debug: Boolean,
    val testBuild: Boolean,
    endpoint: String,
    apiEndpoint: String,
    /** `platform/version` of the SDK as batches name it (`android/1.0.0`, `react_native/1.0.0`). */
    val sdk: String,
    /** Activities, fragments: off for a wrapper that names its own screens. */
    val automaticScreens: Boolean = true,
    /**
     * A wrapper whose toolkit draws its own widgets (Flutter): it measures engagement, taps, scroll and forms itself,
     * and takes the screen images; the SDK keeps sessions, `screen` events and transport.
     */
    val screens: net.scruter.bridge.ScruterBridge.ScreenListener? = null,
) {
    val endpoint: String = endpoint.trimEnd('/')
    val apiEndpoint: String = apiEndpoint.trimEnd('/')

    companion object {
        const val ENDPOINT = "https://cdn.scruter.net"
        const val API_ENDPOINT = "https://api.scruter.net"

        /** `^[A-Z0-9_-]{1,32}$`, without a regular expression: `start` runs on the main thread. */
        fun validAppId(id: String): Boolean =
            id.length in 1..32 && id.all { it in 'A'..'Z' || it in '0'..'9' || it == '_' || it == '-' }
    }
}
