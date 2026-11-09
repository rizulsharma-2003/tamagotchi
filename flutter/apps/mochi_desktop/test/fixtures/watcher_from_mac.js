/**
 * Mochi Watcher: wakes Mochi Cloud only when something new arrives, so Claude runs for real news.
 * It runs free inside your own Google account (script.google.com): no server, no API key.
 *
 * - Calendar: Google calls calendarChanged() the moment an event is added or changed.
 * - Gmail: checkMail() looks every 5 minutes for new unread inbox mail (not Promotions, Social or Forums) and
 *   hands Mochi Cloud exactly those threads. With VIPs (set on your Mac), only their mail wakes it; the rest
 *   waits for the morning and night summaries.
 * - Meetings: the same 5-minute look sends a heads-up about 10 minutes before each meeting, with a Join
 *   button when it has a video link (once per meeting; not all-day events or ones you declined).
 * - Only between 08:00 and 23:00, and at most one wake every 10 minutes; news that arrives in between
 *   is picked up by the next wake.
 *
 * Set up: paste this into a new project at script.google.com, pick "setup" next to the Run button, press
 * Run and allow access. Run "stop" to switch it off.
 */
const MOCHI = {
  fireUrl: 'https://api.anthropic.com/v1/claude_code/routines/trig_012eNQcMDqqHfiWcYGoXKjts/fire',
  token: 'sk-ant-oat01-abc_DEF-123',
  timeZone: 'Asia/Kolkata',
  fromHour: 8,
  untilHour: 23,
  minutesBetweenWakes: 10,
  headsUpMinutes: 10,
  // Names, addresses or @domains (from Settings › Agent › VIPs on your Mac).
  vips: ["Amogh","@insideedge.club"],
};
const NEW_MAIL = 'is:unread in:inbox newer_than:1d -category:promotions -category:social -category:forums';

function setup() {
  stop();
  ScriptApp.newTrigger('checkMail').timeBased().everyMinutes(5).create();
  ScriptApp.newTrigger('calendarChanged').forUserCalendar(Session.getEffectiveUser().getEmail()).onEventUpdated().create();
  // What's in the inbox now counts as seen: only mail from here on wakes Mochi.
  remember_(GmailApp.search(NEW_MAIL, 0, 50).map(function (thread) { return thread.getId(); }));
  Logger.log('Mochi Watcher is on.');
}

function stop() {
  ScriptApp.getProjectTriggers().forEach(function (trigger) { ScriptApp.deleteTrigger(trigger); });
}

function checkMail() {
  if (!awake_()) return;
  checkMeetings_();
  var seen = seen_();
  var fresh = GmailApp.search(NEW_MAIL, 0, 30).filter(function (thread) { return !seen[thread.getId()]; });
  if (fresh.length) {
    remember_(fresh.map(function (thread) { return thread.getId(); }));
    // With VIPs, only their mail is worth waking Mochi for; VIP threads are marked with a star.
    var wanted = fresh.map(function (thread) { return (vip_(thread) ? '*' : '') + thread.getId(); })
      .filter(function (id) { return !MOCHI.vips.length || id.charAt(0) === '*'; });
    if (wanted.length) {
      queue_(wanted);
      wake_('new mail');
      return;
    }
  }
  if (props_().getProperty('pending')) wake_('news from earlier');
}

// The latest message's sender is one of your VIPs.
function vip_(thread) {
  if (!MOCHI.vips.length) return false;
  var messages = thread.getMessages();
  var from = String(messages[messages.length - 1].getFrom()).toLowerCase();
  var match = from.match(/<([^>]+)>/);
  var address = (match ? match[1] : from).trim();
  var name = match ? from.slice(0, from.indexOf('<')).replace(/["']/g, '').trim() : '';
  return MOCHI.vips.some(function (raw) {
    var vip = String(raw).trim().toLowerCase();
    if (!vip) return false;
    if (vip.charAt(0) === '@') return address.slice(-vip.length) === vip;
    if (vip.indexOf('@') >= 0) return address === vip;
    return name.indexOf(vip) >= 0;
  });
}

// Threads waiting to be handed to Mochi Cloud (at most 10, newest first).
function queue_(ids) {
  var waiting = read_('queue');
  var list = (waiting.ids || []).filter(function (id) { return ids.indexOf(id) < 0; });
  props_().setProperty('queue', JSON.stringify({ ids: ids.concat(list).slice(0, 10) }));
}

function calendarChanged() {
  if (awake_()) wake_('calendar change');
}

// A meeting starting in the next 10–20 minutes that hasn't had its heads-up yet.
function checkMeetings_() {
  var now = Date.now();
  var from = new Date(now + (MOCHI.headsUpMinutes - 5) * 60000);
  var to = new Date(now + (MOCHI.headsUpMinutes + 5) * 60000);
  var told = read_('headsUp');
  var next = CalendarApp.getDefaultCalendar().getEvents(from, to).filter(function (event) {
    return !event.isAllDayEvent() && event.getMyStatus() !== CalendarApp.GuestStatus.NO
      && !told[event.getId() + '@' + event.getStartTime().getTime()];
  })[0];
  if (!next || !fire_('soon ' + Math.floor(next.getStartTime().getTime() / 1000), 'meeting heads-up')) return;
  told[next.getId() + '@' + next.getStartTime().getTime()] = Math.floor(now / 1000);
  Object.keys(told).forEach(function (key) { if (now / 1000 - told[key] > 86400) delete told[key]; });
  props_().setProperty('headsUp', JSON.stringify(told));
}

function awake_() {
  var hour = Number(Utilities.formatDate(new Date(), MOCHI.timeZone, 'H'));
  return hour >= MOCHI.fromHour && hour < MOCHI.untilHour;
}

function wake_(reason) {
  var props = props_();
  var now = Math.floor(Date.now() / 1000);
  var last = Number(props.getProperty('lastWake') || 0);
  if (now - last < MOCHI.minutesBetweenWakes * 60) {
    props.setProperty('pending', '1');
    return;
  }
  // Since a little before the last wake (at most six hours back), with the exact new threads ("-" for none:
  // a calendar change only).
  var since = Math.max(last - 120, now - 6 * 3600);
  var ids = (read_('queue').ids || []).join(',') || '-';
  if (fire_('new ' + since + ' ' + ids, reason)) {
    props.setProperty('lastWake', String(now));
    props.deleteProperty('pending');
    props.deleteProperty('queue');
  } else {
    props.setProperty('pending', '1');
  }
}

// Starts Mochi Cloud with what to look at; true when it accepted.
function fire_(text, reason) {
  var response = UrlFetchApp.fetch(MOCHI.fireUrl, {
    method: 'post',
    contentType: 'application/json',
    muteHttpExceptions: true,
    headers: {
      'Authorization': 'Bearer ' + MOCHI.token,
      'anthropic-beta': 'experimental-cc-routine-2026-04-01',
      'anthropic-version': '2023-06-01',
    },
    payload: JSON.stringify({ text: text }),
  });
  var code = response.getResponseCode();
  Logger.log(reason + ': Mochi Cloud answered ' + code);
  return code < 300;
}

function read_(key) {
  try {
    return JSON.parse(props_().getProperty(key) || '{}');
  } catch (error) {
    return {};
  }
}

function props_() {
  return PropertiesService.getUserProperties();
}

function seen_() {
  return read_('seen');
}

function remember_(ids) {
  var seen = seen_();
  var now = Math.floor(Date.now() / 1000);
  ids.forEach(function (id) { seen[id] = now; });
  // Three days, at most 250 threads (one property holds 9 KB).
  var kept = {};
  Object.keys(seen)
    .filter(function (id) { return now - seen[id] < 3 * 86400; })
    .sort(function (a, b) { return seen[b] - seen[a]; })
    .slice(0, 250)
    .forEach(function (id) { kept[id] = seen[id]; });
  props_().setProperty('seen', JSON.stringify(kept));
}