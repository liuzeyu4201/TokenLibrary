import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir:'./tests', timeout:30000, fullyParallel:false,
  use:{baseURL:'http://127.0.0.1:8766', headless:true, launchOptions:{executablePath:process.env.TL_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}, screenshot:'only-on-failure'},
  webServer:{command:'node test-server.mjs', url:'http://127.0.0.1:8766', reuseExistingServer:false},
  reporter:[['list'],['json',{outputFile:'test-results/results.json'}]],
});
