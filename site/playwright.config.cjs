const { defineConfig } = require('@playwright/test');
module.exports = defineConfig({
  testDir: './tests',
  workers: 2,
  retries: 0,
  reporter: 'list',
  use: { baseURL: 'http://127.0.0.1:4387', reducedMotion: 'reduce' },
  projects: ['chromium', 'firefox', 'webkit'].flatMap(browserName => [375, 1440].map(width => ({
    name: `${browserName}-${width}`,
    use: { browserName, viewport: { width, height: 900 } },
  }))),
  webServer: { command: 'python3 -m http.server 4387 --bind 127.0.0.1 --directory dist', url: 'http://127.0.0.1:4387', reuseExistingServer: false },
});
