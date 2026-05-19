'use strict';

const { logger } = require('ee-core/log');

function preload() {
  logger.info('[preload] loaded');
}

module.exports = { preload };
