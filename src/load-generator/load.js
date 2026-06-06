// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import http from 'k6/http';
import { sleep } from 'k6';
import { SharedArray } from 'k6/data';
import tracing from 'k6/x/tracing';
import { browser } from 'k6/browser';
import { instrumentHTTP } from './vendor/http-instrumentation-tempo.js';

// Custom config uses a LOADGEN_ prefix: K6_VUS / K6_DURATION etc. are reserved
// k6 option env vars and would override the scenarios block entirely.
const HOST = __ENV.LOADGEN_HOST || 'http://frontend-proxy:8080';
const VUS = Number(__ENV.LOADGEN_VUS || 5);
const DURATION = __ENV.LOADGEN_DURATION || '8760h';
const TRACE_ENDPOINT = __ENV.LOADGEN_TRACING_ENDPOINT || 'otel-collector:4317';
const FLAGD_HOST = __ENV.FLAGD_HOST || 'flagd';
const FLAGD_OFREP_PORT = __ENV.FLAGD_OFREP_PORT || '8016';
const BROWSER_ENABLED = ['true', 'yes', 'on'].includes((__ENV.LOADGEN_BROWSER_TRAFFIC_ENABLED || '').toLowerCase());

// Instrument the http module so every request carries a W3C traceparent,
// mirroring the previous Locust setup's RequestsInstrumentor.
instrumentHTTP({ propagator: 'w3c' });

// xk6-client-tracing client: emits the load generator's own spans so it
// appears as a service in the trace backend.
const traceClient = new tracing.Client({
  endpoint: TRACE_ENDPOINT,
  exporter: tracing.EXPORTER_OTLP,
  tls: { insecure: true },
});

const people = new SharedArray('people', () => JSON.parse(open('./people.json')));

const products = [
  '0PUK6V6EV0', '1YMWWN1N4O', '2ZYFJ3GM2N', '66VCHSJNUP', '6E92ZMYYFZ',
  '9SIQT8TOJO', 'L9ECAV7KIM', 'LS4PSXUNUM', 'OLJCESPC7Z', 'HQTGWGPNH4',
];

const categories = [
  'binoculars', 'telescopes', 'accessories', 'assembly', 'travel', 'books', null,
];

const SERVICE = 'load-generator';
const span = (name, attributes = {}) =>
  traceClient.push(new tracing.TemplatedGenerator({ spans: [{ service: SERVICE, name, attributes }] }).traces());

const sessionId = uuid();
const baggage = () => ({ headers: { baggage: `synthetic_request=true,session.id=${sessionId}` } });

const randInt = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;
const choice = (arr) => arr[randInt(0, arr.length - 1)];

function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

function flagValue(flag) {
  const res = http.post(
    `http://${FLAGD_HOST}:${FLAGD_OFREP_PORT}/ofrep/v1/evaluate/flags/${flag}`,
    JSON.stringify({ context: {} }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  try {
    return Number(res.json('value')) || 0;
  } catch (_e) {
    return 0;
  }
}

function index() {
  span('user_index');
  console.info('User accessing index page');
  http.get(`${HOST}/`, baggage());
}

function browseProduct() {
  const product = choice(products);
  span('user_browse_product', { 'product.id': product });
  console.info(`User browsing product: ${product}`);
  http.get(`${HOST}/api/products/${product}`, baggage());
}

function getRecommendations() {
  const product = choice(products);
  span('user_get_recommendations', { 'product.id': product });
  console.info(`User getting recommendations for product: ${product}`);
  http.get(`${HOST}/api/recommendations?productIds=${product}`, baggage());
}

function getProductReviews() {
  const product = choice(products);
  span('user_get_product_reviews', { 'product.id': product });
  console.info(`User getting product reviews for product: ${product}`);
  http.get(`${HOST}/api/product-reviews/${product}`, baggage());
}

function askProductAiAssistant() {
  const product = choice(products);
  span('user_ask_product_ai_assistant', { 'product.id': product });
  console.info(`Asking the AI assistant about product reviews for: ${product}`);
  http.post(
    `${HOST}/api/product-ask-ai-assistant/${product}`,
    JSON.stringify({ question: 'Can you summarize the product reviews?' }),
    { headers: { ...baggage().headers, 'Content-Type': 'application/json' } },
  );
}

function getAds() {
  const category = choice(categories);
  span('user_get_ads', { category: String(category) });
  console.info(`User getting ads for category: ${category}`);
  http.get(`${HOST}/api/data/?contextKeys=${category}`, baggage());
}

function viewCart() {
  span('user_view_cart');
  console.info('User viewing cart');
  http.get(`${HOST}/api/cart`, baggage());
}

function addToCart(user) {
  const userId = user || uuid();
  const product = choice(products);
  const quantity = choice([1, 2, 3, 4, 5, 10]);
  span('user_add_to_cart', { 'user.id': userId, 'product.id': product, quantity });
  console.info(`User ${userId} adding ${quantity} of product ${product} to cart`);
  http.get(`${HOST}/api/products/${product}`, baggage());
  http.post(
    `${HOST}/api/cart`,
    JSON.stringify({ item: { productId: product, quantity }, userId }),
    { headers: { ...baggage().headers, 'Content-Type': 'application/json' } },
  );
  return userId;
}

function checkout() {
  const user = uuid();
  span('user_checkout_single', { 'user.id': user });
  addToCart(user);
  const person = { ...choice(people), userId: user };
  http.post(`${HOST}/api/checkout`, JSON.stringify(person), {
    headers: { ...baggage().headers, 'Content-Type': 'application/json' },
  });
  console.info(`Checkout completed for user ${user}`);
}

function checkoutMulti() {
  const user = uuid();
  const itemCount = choice([2, 3, 4]);
  span('user_checkout_multi', { 'user.id': user, 'item.count': itemCount });
  for (let i = 0; i < itemCount; i++) {
    addToCart(user);
  }
  const person = { ...choice(people), userId: user };
  http.post(`${HOST}/api/checkout`, JSON.stringify(person), {
    headers: { ...baggage().headers, 'Content-Type': 'application/json' },
  });
  console.info(`Multi-item checkout completed for user ${user}`);
}

function floodHome() {
  const floodCount = flagValue('loadGeneratorFloodHomepage');
  if (floodCount > 0) {
    span('user_flood_home', { 'flood.count': floodCount });
    console.info(`User flooding homepage ${floodCount} times`);
    for (let i = 0; i < floodCount; i++) {
      http.get(`${HOST}/`, baggage());
    }
  }
}

const tasks = [
  { fn: index, weight: 1 },
  { fn: browseProduct, weight: 10 },
  { fn: getRecommendations, weight: 3 },
  { fn: getProductReviews, weight: 2 },
  { fn: askProductAiAssistant, weight: 1 },
  { fn: getAds, weight: 3 },
  { fn: viewCart, weight: 3 },
  { fn: addToCart, weight: 2 },
  { fn: checkout, weight: 1 },
  { fn: checkoutMulti, weight: 1 },
  { fn: floodHome, weight: 5 },
];

const weighted = tasks.flatMap((t, i) => Array(t.weight).fill(i));

export function apiTask() {
  tasks[choice(weighted)].fn();
  sleep(randInt(1, 10));
}

// The frontend loads its web SDK via an async import and the OTLP exporter
// batches on a timer, so RUM only leaves the page seconds after the load
// event; closing sooner silently drops every frontend-web signal.
const RUM_FLUSH_MS = 5000;

export async function browserTask() {
  const page = await browser.newPage();
  try {
    await page.setExtraHTTPHeaders({ baggage: 'synthetic_request=true' });
    if (Math.random() < 0.5) {
      span('browser_change_currency');
      await page.goto(`${HOST}/cart`, { waitUntil: 'load' });
      await page.locator('[name="currency_code"]').selectOption('CHF');
      await page.waitForTimeout(RUM_FLUSH_MS);
    } else {
      // k6/browser uses standard CSS selectors (no Playwright :has-text), so
      // drive the RUM-instrumented frontend by navigation rather than by text.
      const product = choice(products);
      span('browser_browse_product', { 'product.id': product });
      await page.goto(`${HOST}/`, { waitUntil: 'load' });
      await page.waitForTimeout(RUM_FLUSH_MS);
      await page.goto(`${HOST}/product/${product}`, { waitUntil: 'load' });
      await page.waitForTimeout(RUM_FLUSH_MS);
    }
  } catch (e) {
    console.error(`browser task error: ${e}`);
  } finally {
    await page.close();
  }
}

export function teardown() {
  traceClient.shutdown();
}

const scenarios = {
  api: { executor: 'constant-vus', exec: 'apiTask', vus: VUS, duration: DURATION },
};

if (BROWSER_ENABLED) {
  scenarios.browser = {
    executor: 'constant-vus',
    exec: 'browserTask',
    vus: Number(__ENV.LOADGEN_BROWSER_VUS || 1),
    duration: DURATION,
    options: { browser: { type: 'chromium' } },
  };
}

export const options = { scenarios, setupTimeout: '60s' };
