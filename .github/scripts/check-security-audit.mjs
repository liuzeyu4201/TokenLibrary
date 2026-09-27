import fs from "node:fs";

const findingsPath = process.argv[2];

if (!findingsPath || !fs.existsSync(findingsPath)) {
  console.log(
    "security-audit: findings.json is absent. The run is incomplete, so this check does not fail.",
  );
  process.exit(0);
}

let findings;
try {
  findings = JSON.parse(fs.readFileSync(findingsPath, "utf8"));
} catch (error) {
  console.error(`security-audit: findings.json is not valid JSON: ${error.message}`);
  process.exit(1);
}

if (!Array.isArray(findings)) {
  console.error("security-audit: findings.json must be a JSON array.");
  process.exit(1);
}

const counts = { confirmed: 0, needs_validation: 0, rejected: 0, other: 0 };
const blocking = [];

for (const item of findings) {
  const verdict = item && item.verdict;
  if (Object.hasOwn(counts, verdict)) counts[verdict] += 1;
  else counts.other += 1;
  if (verdict !== "confirmed") continue;
  const overall = String(item.severity?.overall_severity ?? "").toLowerCase();
  if (overall === "high" || overall === "critical" || overall === "") {
    blocking.push({
      overall: overall || "missing",
      title: item.title || item.fingerprint || "(untitled)",
    });
  }
}

console.log(
  `security-audit: confirmed=${counts.confirmed} needs_validation=${counts.needs_validation} rejected=${counts.rejected} other=${counts.other}`,
);

if (blocking.length === 0) {
  console.log("security-audit: no confirmed high or critical findings.");
  process.exit(0);
}

console.error("security-audit: blocking confirmed findings:");
for (const finding of blocking) {
  console.error(`- [${finding.overall}] ${finding.title}`);
}
process.exit(1);
