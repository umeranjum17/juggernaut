// helpdesk CLI, skeleton commit: the app builds and starts, and knows no command yet.
// The objective journeys run against this and fail on their named assertion (formats.md section 7; spec Objectives).
const command = process.argv[process.argv[3] === "--now" ? 5 : 3];
process.stdout.write(`helpdesk: unknown command ${command ?? ""}\n`);
process.exit(2);
