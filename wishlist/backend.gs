// Westside App Wishlist — Google Apps Script backend
// Deployed as a Web app (Execute as: Me, Who has access: Anyone).
// The deployed /exec URL is set in wishlist/index.html as SCRIPT_URL.
//
// Storage: auto-creates a "Westside App Wishlist" Google Sheet in Drive on first
// run and remembers its id via Script Properties. Every submission is one row.
// doGet + tally_ return per-feature vote counts that the page shows live.
//
// NOTIFY: comma-separated recipients pinged on each submission (email + SMS
// gateway). Leave "" for no alerts.

const NOTIFY = "josephwcook@gmail.com,3527577345@tmomail.net";

function getSheet_() {
  const props = PropertiesService.getScriptProperties();
  let id = props.getProperty('SHEET_ID');
  let ss;
  if (id) {
    ss = SpreadsheetApp.openById(id);
  } else {
    ss = SpreadsheetApp.create('Westside App Wishlist');
    props.setProperty('SHEET_ID', ss.getId());
  }
  let sheet = ss.getSheetByName('Submissions');
  if (!sheet) sheet = ss.insertSheet('Submissions');
  if (sheet.getLastRow() === 0) sheet.appendRow(['Timestamp', 'Name', 'Contact', 'Note', 'Picks JSON']);
  return sheet;
}

function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    const sheet = getSheet_();
    sheet.appendRow([new Date(), body.name || '', body.contact || '', body.note || '', JSON.stringify(body.picks || {})]);
    if (NOTIFY) {
      const yes = Object.values(body.picks || {}).filter(function (p) { return p && p.want === 'yes'; }).length;
      MailApp.sendEmail(NOTIFY, 'App wishlist: ' + (body.name || 'someone'), (body.name || 'Someone') + ' picked ' + yes + ' features.');
    }
    return json_(tally_());
  } catch (err) { return json_({ error: String(err) }); }
}

function doGet() { return json_(tally_()); }

function tally_() {
  const sheet = getSheet_();
  const counts = {}; let total = 0;
  if (sheet.getLastRow() > 1) {
    const rows = sheet.getRange(2, 5, sheet.getLastRow() - 1, 1).getValues();
    rows.forEach(function (r) {
      total++;
      let picks = {};
      try { picks = JSON.parse(r[0] || '{}'); } catch (e) {}
      Object.keys(picks).forEach(function (k) {
        const p = picks[k] || {};
        if (p.want === 'yes') { counts[k] = counts[k] || { y: 0, s: 0 }; counts[k].y++; if (p.star) counts[k].s++; }
      });
    });
  }
  return { total: total, counts: counts };
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
