module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/__tests__/**/*.test.[jt]s?(x)'],
  moduleNameMapper: { '^react-native$': '<rootDir>/__mocks__/react-native.ts' },
  modulePathIgnorePatterns: ['<rootDir>/example', '<rootDir>/lib'],
  testPathIgnorePatterns: ['/node_modules/', '<rootDir>/example'],
  globals: { __DEV__: false },
};
