const fs = require('fs');
const os = require('os');
const path = require('path');

const RGRAPH = /^Using graph .*\/(.*?)\.mtx \.\.\./m;
const RMODLR = /^modularity: (.+)$/m;
const RTIMES = /^algorithm_time: (.+?) all_time: (.+)$/m;
const RCOMMS = /^communities: (\d+)$/m;




// *-FILE
// ------

function readFile(pth) {
  var d = fs.readFileSync(pth, 'utf8');
  return d.replace(/\r?\n/g, '\n');
}

function writeFile(pth, d) {
  d = d.replace(/\r?\n/g, os.EOL);
  fs.writeFileSync(pth, d);
}




// *-CSV
// -----

function writeCsv(pth, rows) {
  var cols = Object.keys(rows[0]);
  var a = cols.join()+'\n';
  for (var r of rows)
    a += [...Object.values(r)].map(v => `"${v}"`).join()+'\n';
  writeFile(pth, a);
}




// *-LOG
// -----

function readLogLine(ln, data, state) {
  if (RGRAPH.test(ln)) {
    var [, graph] = RGRAPH.exec(ln);
    if (!data.has(graph)) data.set(graph, []);
    state = {graph};
  }
  else if (RMODLR.test(ln)) {
    var [, modularity] = RMODLR.exec(ln);
    state.modularity = parseFloat(modularity);
  }
  else if (RTIMES.test(ln)) {
    var [, algorithm_time, all_time] = RTIMES.exec(ln);
    state.algorithm_time = parseFloat(algorithm_time);
    state.all_time       = parseFloat(all_time);
  }
  else if (RCOMMS.test(ln)) {
    var [, communities] = RCOMMS.exec(ln);
    data.get(state.graph).push(Object.assign({}, state, {
      communities: parseFloat(communities),
    }));
  }
  return state;
}

function readLog(pth) {
  var text = readFile(pth);
  var lines = text.split('\n');
  var data = new Map();
  var state = null;
  for (var ln of lines)
    state = readLogLine(ln, data, state);
  return data;
}




// PROCESS-*
// ---------

function processCsv(data) {
  var a = [];
  for (var rows of data.values())
    a.push(...rows);
  return a;
}




// MAIN
// ----

function main(cmd, log, out) {
  var data = readLog(log);
  if (path.extname(out)==='') cmd += '-dir';
  switch (cmd) {
    case 'csv':
      var rows = processCsv(data);
      writeCsv(out, rows);
      break;
    case 'csv-dir':
      for (var [graph, rows] of data)
        writeCsv(path.join(out, graph+'.csv'), rows);
      break;
    default:
      console.error(`error: "${cmd}"?`);
      break;
  }
}
main(...process.argv.slice(2));
