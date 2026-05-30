# ETHOS GPS Heading

Very small ETHOS widget that:

- reads GPS latitude/longitude using ETHOS telemetry sources
- derives a course-over-ground heading from position changes
- publishes that heading into a custom telemetry sensor named `GPS Heading`
- uses lazy loading so startup stays tiny

## Layout

- `src/gps-heading`: widget source copied by the VS Code deploy script
- `.vscode`: deployment/debug setup adapted from `omp-ofs3-dashboard`

## Notes

- The derived heading is meaningful only when the model is moving.
- The custom `GPS Heading` sensor is populated while this widget is running on an active screen.
- The custom sensor appId is `0xEF01`.
