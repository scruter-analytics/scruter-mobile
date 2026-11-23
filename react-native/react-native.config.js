// Named, because autolinking takes the first class it finds that extends a package: PackageBase would be it.
module.exports = {
  dependency: {
    platforms: {
      android: {
        packageImportPath: 'import net.scruter.reactnative.ScruterPackage;',
        packageInstance: 'new ScruterPackage()',
      },
    },
  },
};
