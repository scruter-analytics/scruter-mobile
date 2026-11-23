# Scruter CMP — rules applied to the app's R8 build.
#
# The module needs no keep rule of its own: it uses no reflection on its own classes. The detected SDKs (docs/CMP-MOBILE.md
# §3.14) look up the catalogue's class names with Class.forName(name, false, loader); catalogue-rules.pro keeps those
# names only (-keepnames: R8 still removes an SDK the app does not use), and nothing else of the app.
