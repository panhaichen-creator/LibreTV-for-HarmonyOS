const path = require('node:path');

// Use an explicit SDK module, an existing dependency, or the default macOS SDK.
if (process.env.TYPESCRIPT_PATH) {
  module.exports = require(path.resolve(process.env.TYPESCRIPT_PATH));
} else {
  try {
    module.exports = require('typescript');
  } catch (error) {
    const studio = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
    module.exports = require(path.join(studio, 'tools/arktsdoc/node_modules/typescript'));
  }
}
