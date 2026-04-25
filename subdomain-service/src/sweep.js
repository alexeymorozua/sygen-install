import { deleteDnsRecord, CfApiError } from "./lib/cf.js";

// Daily sweep — caps at MAX_PER_RUN expired entries to keep scheduled
// invocations under the Worker time budget. Whatever's left over rolls
// to tomorrow's run.
const MAX_PER_RUN = 200;
const MAX_PAGES = 10;

export async function sweepExpired(env, nowMs = Date.now()) {
  let cursor = undefined;
  let scanned = 0;
  let swept = 0;
  let dnsErrors = 0;
  let entryErrors = 0;

  for (let page = 0; page < MAX_PAGES; page++) {
    let listing;
    try {
      listing = await env.SUBDOMAIN_RESERVATIONS.list({ cursor, limit: 1000 });
    } catch (e) {
      console.error("sweep: list_failed", { page, message: e.message });
      break;
    }

    const expired = [];
    for (const key of listing.keys) {
      scanned++;
      try {
        const raw = await env.SUBDOMAIN_RESERVATIONS.get(key.name);
        if (!raw) continue;
        const r = JSON.parse(raw);
        const exp = Date.parse(r.expires_at);
        if (Number.isNaN(exp) || exp >= nowMs) continue;
        expired.push(r);
        if (expired.length + swept >= MAX_PER_RUN) break;
      } catch (e) {
        entryErrors++;
        console.error("sweep: read_failed", { key: key.name, message: e.message });
      }
    }

    // Process this page's expired entries in parallel — independent
    // reservations don't share state.
    const results = await Promise.allSettled(expired.map((r) => deleteOne(env, r)));
    for (const res of results) {
      if (res.status === "fulfilled") swept++;
      else {
        if (res.reason instanceof CfApiError) dnsErrors++;
        else entryErrors++;
      }
    }

    if (listing.list_complete || swept >= MAX_PER_RUN) break;
    cursor = listing.cursor;
  }

  console.log("sweep: done", { scanned, swept, dnsErrors, entryErrors });
  return { scanned, swept, dnsErrors, entryErrors };
}

async function deleteOne(env, reservation) {
  if (reservation.cf_record_id) {
    try {
      await deleteDnsRecord(env, reservation.cf_record_id);
    } catch (e) {
      // 404 from CF means the record is already gone — treat as success
      // for the purpose of cleanup. Anything else propagates.
      if (!(e instanceof CfApiError) || e.status !== 404) throw e;
    }
  }
  await Promise.all([
    env.SUBDOMAIN_RESERVATIONS.delete(reservation.subdomain),
    reservation.install_token_hash
      ? env.TOKEN_INDEX.delete(reservation.install_token_hash)
      : Promise.resolve(),
  ]);
}
