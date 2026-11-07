'use strict';
// The symbols API (docs/API.md §5.3): which files are missing, a presigned upload, `complete`.
const crypto = require('node:crypto');

const RETRIES = 3;
// Requests are small; an upload is ≤ a few hundred MB of gzip, the presigned URL lives 15 minutes.
const REQUEST_TIMEOUT = 60000;
const UPLOAD_TIMEOUT = 15 * 60000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function retryAfter(res) {
  const s = Number(res.headers.get('retry-after'));
  return Number.isFinite(s) && s > 0 ? Math.min(s, 60) * 1000 : 2000;
}

class Client {
  constructor({ api, token, app, fetchImpl = fetch, wait = sleep }) {
    this.api = api.replace(/\/+$/, '');
    this.token = token;
    this.app = app;
    this.fetch = fetchImpl;
    this.wait = wait;
  }

  async request(url, init) {
    for (let attempt = 0; ; attempt++) {
      let res;
      try {
        const timeout = init.method === 'POST' ? REQUEST_TIMEOUT : UPLOAD_TIMEOUT;
        res = await this.fetch(url, { ...init, signal: AbortSignal.timeout(timeout) });
      } catch (e) {
        if (attempt >= RETRIES) throw new Error(`no answer from ${new URL(url).host}: ${e.message}`);
        await this.wait(2000);
        continue;
      }
      if ((res.status === 429 || res.status >= 500) && attempt < RETRIES) {
        await this.wait(retryAfter(res));
        continue;
      }
      return res;
    }
  }

  async post(path, body) {
    return this.request(`${this.api}${path}`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.token}`,
        'Content-Type': 'application/json',
        'User-Agent': 'scruter-cli/1.0.1',
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  }

  /** The ones of `files` ({kind, debug_id}) the server does not have. */
  async missing(files) {
    const res = await this.post('/m/v1/symbols/missing', { app: this.app, files });
    if (!res.ok) throw new Error(failure('the list of missing symbols', res.status));
    const body = await res.json();
    return Array.isArray(body.missing) ? body.missing : [];
  }

  /** The four steps of §4.3 for one file; true when uploaded, false when the server already had it. */
  async send(file, bytes) {
    const declaration = {
      app: this.app,
      platform: file.platform,
      kind: file.kind,
      debug_id: file.debug_id,
      app_version: file.app_version,
      build: file.build,
      file_name: file.file_name,
      size: bytes.length,
      sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    };
    const res = await this.post('/m/v1/symbols', declaration);
    if (res.status === 409) return false;
    if (res.status !== 201) throw new Error(failure(file.file_name, res.status));
    const { id, upload } = await res.json();
    const put = await this.request(upload.url, { method: upload.method ?? 'PUT', headers: upload.headers, body: bytes });
    if (!put.ok) throw new Error(failure(`the upload of ${file.file_name}`, put.status));
    const done = await this.post(`/m/v1/symbols/${encodeURIComponent(id)}/complete`);
    if (!done.ok) throw new Error(failure(`the end of ${file.file_name}`, done.status));
    return true;
  }
}

function failure(what, status) {
  if (status === 401) return `${what}: the upload token is unknown or revoked (App settings › SDK)`;
  if (status === 403) return `${what}: this token belongs to another app`;
  return `${what}: answer ${status}`;
}

module.exports = { Client };
