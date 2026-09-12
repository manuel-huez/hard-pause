import js from '@eslint/js';

export default [
  js.configs.recommended,
  {
    files: ['web/tests/*.spec.cjs'],
    languageOptions: { globals: { document: 'readonly', innerWidth: 'readonly' } },
  },
  {
    files: ['web/app.js', 'web/mascot/*.js'],
    languageOptions: { globals: { document: 'readonly', URL: 'readonly' } },
  },
  {
    files: ['web/tests/*.cjs', 'scripts/*.cjs', 'playwright.config.cjs'],
    languageOptions: {
      sourceType: 'commonjs',
      globals: { __dirname: 'readonly', URL: 'readonly' },
    },
  },
];
