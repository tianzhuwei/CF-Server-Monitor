import { initDatabase, cleanupOldData } from './database/schema.js';
import { handleAdminAPI } from './handlers/admin.js';
import { handleAdminUI } from './handlers/admin-ui.js';
import { handleUpdate } from './handlers/update.js';
import { handleDashboard, handleServerDetail, handleServerAPI, handleServersAPI } from './handlers/dashboard.js';
import { loadSettings } from './utils/settings.js';
import { checkAuth, authResponse } from './middleware/auth.js';

const historyCache = new Map();
const CACHE_TTL = 60000;
const MAX_HOURS = 72;

function getBucketSeconds(hours) {
  if (hours <= 12) return 120;
  if (hours <= 24) return 300;
  if (hours <= 48) return 600;
  return 1200;
}

async function getMetricsHistory(db, serverId, rangeHours, columns) {
  const bucketSeconds = getBucketSeconds(rangeHours);
  const now = Date.now();
  const cutoff = now - (rangeHours * 60 * 60 * 1000);
  
  const selectColumns = columns.split(',').map(col => `b1.${col.trim()}`).join(', ');
  
  const query = `
    WITH bucketed AS (
      SELECT id, server_id, timestamp, ${columns},
        CAST(timestamp / (? * 1000) AS INTEGER) AS bucket
      FROM metrics_history
      WHERE server_id = ?
        AND typeof(timestamp) = 'integer'
        AND timestamp >= ?
    )
    SELECT b1.id, b1.server_id, b1.timestamp, ${selectColumns}
    FROM bucketed b1
    WHERE b1.timestamp = (
      SELECT MIN(b2.timestamp)
      FROM bucketed b2
      WHERE b2.bucket = b1.bucket
    )
    ORDER BY b1.timestamp ASC
  `;
  
  const result = await db.prepare(query)
    .bind(bucketSeconds, serverId, cutoff)
    .all();
  
  return result.results;
}

async function fetchHistoryData(env, sys, request, id, hours, columns) {
  if (sys.is_public !== 'true' && !checkAuth(request, env)) {
    return authResponse(sys.site_title);
  }
  
  if (!id) return new Response('Missing ID', { status: 400 });
  
  const isLoggedIn = checkAuth(request, env);
  let serverQuery = 'SELECT id FROM servers WHERE id = ?';
  if (!isLoggedIn) {
    serverQuery += " AND is_hidden != '1'";
  }
  const server = await env.DB.prepare(serverQuery).bind(id).first();
  if (!server) return new Response('Not Found', { status: 404 });
  
  const clampedHours = Math.min(hours, MAX_HOURS);
  
  const cacheKey = `${id}_${clampedHours}_${columns}`;
  const cached = historyCache.get(cacheKey);
  if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
    return new Response(JSON.stringify(cached.data), {
      headers: { 'Content-Type': 'application/json', 'X-Cache': 'HIT' }
    });
  }
  
  const sampled = await getMetricsHistory(env.DB, id, clampedHours, columns);
  
  const processed = sampled.map(row => {
    let ts = row.timestamp;
    if (typeof ts === 'string') {
      ts = new Date(ts).getTime();
    }
    return {
      ...row,
      timestamp: ts
    };
  });
  
  historyCache.set(cacheKey, {
    timestamp: Date.now(),
    data: processed
  });
  
  return new Response(JSON.stringify(processed), {
    headers: { 'Content-Type': 'application/json', 'X-Cache': 'MISS' }
  });
}

export default {
  async fetch(request, env, ctx) {
    await initDatabase(env.DB);

    const url = new URL(request.url);
    const sys = await loadSettings(env.DB);
    const method = request.method;
    const path = url.pathname;

    const routes = [
      { method: 'POST', path: '/admin/api', handler: () => handleAdminAPI(request, env, sys) },
      { method: 'GET', path: '/admin', handler: () => handleAdminUI(request, env, sys) },
      { method: 'POST', path: '/update', handler: () => handleUpdate(request, env, ctx) },
      { method: 'GET', path: '/api/server', handler: () => handleServerAPI(request, env, sys) },
      { method: 'GET', path: '/api/servers', handler: () => handleServersAPI(request, env, sys) },
      { method: 'GET', path: '/api/history', handler: () => {
        const id = url.searchParams.get('id');
        const metric = url.searchParams.get('metric') || 'cpu';
        const hours = parseFloat(url.searchParams.get('hours') || '24');
        return fetchHistoryData(env, sys, request, id, hours, metric);
      }},
      { method: 'GET', path: '/api/history/all', handler: () => {
        const id = url.searchParams.get('id');
        const hours = parseFloat(url.searchParams.get('hours') || '24');
        const allColumns = 'cpu, ram, disk, processes, net_in_speed, net_out_speed, tcp_conn, udp_conn, ping_ct, ping_cu, ping_cm, ping_bd';
        return fetchHistoryData(env, sys, request, id, hours, allColumns);
      }},
      { method: 'GET', path: '/', handler: () => {
        const viewId = url.searchParams.get('id');
        if (viewId) {
          return handleServerDetail(request, env, sys, viewId);
        }
        return handleDashboard(request, env, sys);
      }}
    ];

    for (const route of routes) {
      if (route.method === method && route.path === path) {
        return route.handler();
      }
    }

    return new Response('Not Found', { status: 404 });
  },

  async scheduled(event, env, ctx) {
    await initDatabase(env.DB);
    
    console.log('[Cron] 开始执行定时清理任务');
    await cleanupOldData(env.DB);
    console.log('[Cron] 定时清理任务完成');
  }
};