'use strict';

const express = require('express');
const { register, collectDefaultMetrics, Counter, Histogram } = require('prom-client');

const app = express();
const PORT = process.env.PORT || 3000;

// Collect default Node.js runtime metrics (event loop lag, memory, CPU, GC)
collectDefaultMetrics({ prefix: 'nodejs_app_' });

// --- Custom Business Metrics ---

// Counter: total HTTP requests by method, route, and status code
const httpRequestCounter = new Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
});

// Histogram: request duration in seconds, with custom buckets
const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
});

// --- Middleware: record metrics for every request ---
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const labels = {
      method: req.method,
      route: req.route ? req.route.path : req.path,
      status_code: res.statusCode,
    };
    httpRequestCounter.inc(labels);
    end(labels);
  });
  next();
});

app.use(express.json());

// --- Routes ---

// Kubernetes liveness probe
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'alive', timestamp: new Date().toISOString() });
});

// Kubernetes readiness probe — checks actual app readiness
app.get('/readyz', (req, res) => {
  // In production: check DB connections, cache connections, etc.
  res.status(200).json({ status: 'ready', timestamp: new Date().toISOString() });
});

// Prometheus metrics scrape endpoint
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
});

// Application root endpoint
app.get('/', (req, res) => {
  res.status(200).json({
    service: 'k8s-observability-app',
    version: process.env.APP_VERSION || 'unknown',
    build: process.env.BUILD_NUMBER || 'local',
  });
});

// Simulate a work endpoint (for load testing)
app.get('/api/work', (req, res) => {
  // Simulate variable latency
  const delay = Math.floor(Math.random() * 200);
  setTimeout(() => {
    res.status(200).json({ processed: true, delay_ms: delay });
  }, delay);
});

// --- Graceful shutdown ---
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(JSON.stringify({
    level: 'info',
    event: 'server_started',
    port: PORT,
    timestamp: new Date().toISOString(),
  }));
});

const shutdown = (signal) => {
  console.log(JSON.stringify({
    level: 'info',
    event: 'shutdown_initiated',
    signal,
    timestamp: new Date().toISOString(),
  }));
  server.close(() => {
    console.log(JSON.stringify({ level: 'info', event: 'server_closed' }));
    process.exit(0);
  });
  // Force-kill after 10 seconds if graceful shutdown hangs
  setTimeout(() => {
    console.error('Graceful shutdown timed out. Forcing exit.');
    process.exit(1);
  }, 10000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

module.exports = app; // exported for testing
