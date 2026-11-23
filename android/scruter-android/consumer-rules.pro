# Scruter Analytics SDK — rules applied to the app's R8 build.

# Compose, Navigation, Fragment, RecyclerView and Material are optional: the SDK uses them only when the app has them
# (each use behind a probe). An app without them has no reference to keep. These rules apply to the whole app: only what
# the SDK touches, so that a real missing class of the app's still warns.
-dontwarn androidx.compose.runtime.**
-dontwarn androidx.compose.ui.Modifier*
-dontwarn androidx.compose.ui.platform.ViewRootForTest
-dontwarn androidx.compose.ui.semantics.**
-dontwarn androidx.navigation.NavController*
-dontwarn androidx.navigation.NavDestination*
-dontwarn androidx.fragment.app.Fragment*
-dontwarn androidx.fragment.app.DialogFragment
-dontwarn androidx.recyclerview.widget.RecyclerView*
-dontwarn androidx.recyclerview.widget.LinearLayoutManager
-dontwarn com.google.android.material.textfield.TextInputLayout
-dontwarn kotlinx.coroutines.flow.StateFlow

# Automatic screen names (docs/MOBILE.md §3.3): the app's fragments keep their class names (activities already do,
# through the manifest), not those of the libraries, which name no screen. Names only: R8 still removes unused ones.
-keepnames class !androidx.**,!com.google.android.**,* extends androidx.fragment.app.Fragment

# @ScruterScreen("Cart") is read at run time.
-keepattributes RuntimeVisibleAnnotations
-keep @interface net.scruter.ScruterScreen
