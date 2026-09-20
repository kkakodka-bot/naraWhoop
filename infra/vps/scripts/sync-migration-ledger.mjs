import { migrationLedger, requireThat } from './sync-evidence-contract.mjs';

// Exact reviewed basenames emitted by apply-migrations.sh. No remote filesystem discovery,
// arbitrary prefix truncation or ledger writes. New/renamed sources require a reviewed update.
export const SUPPORTED_LEDGER_BASENAMES = Object.freeze([
  '20260819190000_frwhoop_base_schema.sql',
  '20260819193357_frwhoop_storage_v1.sql',
  '20260819194247_frwhoop_storage_grants.sql',
  '20260819194325_frwhoop_revoke_truncate.sql',
  '20260819201044_frwhoop_query_surface.sql',
  '20260823231259_settings_and_integrations.sql',
  '20260824054744_sleep_storage_tables.sql',
  '20260824054807_sleep_storage_rls_views.sql',
  '20260824054842_sleep_storage_query_rpcs.sql',
  '20260824054934_sleep_storage_ingest_rpc.sql',
  '20260824055245_internal_app_secrets_rls.sql',
  '20260824055400_sleep_storage_fk_indexes.sql',
  '20260824055514_sleep_storage_ingest_extras.sql',
  '20260824171406_app_config_and_ingest_rpcs.sql',
  '20260824171719_engine_ingest_rpcs.sql',
  '20260824172642_engine_rpcs_canonical.sql',
  '20260824172649_unify_secret_gate.sql',
  '20260824180000_production_persistence.sql',
  '20260824185725_post_persistence_indexes.sql',
  '20260824190000_settings_identity_canonical.sql',
  '20260824210000_revoke_trigger_execute.sql',
  '20260824220000_canonical_day_series_broadcast.sql',
  '20260824230000_greenfield_engine_rpcs.sql',
  '20260825021116_workout_remote_flags.sql',
  '20260825120000_energy_expenditure.sql',
  '20260825140000_weight_nutrition_longitudinal.sql',
  '20260825180915_gravity_sleep_persistence.sql',
  '20260825194526_healthkit_source_links.sql',
  '20260825201751_healthkit_external_identity.sql',
  '20260826090000_sleep_probability_coverage.sql',
  '20260826120000_day_rpc_authenticated_reads.sql',
  '20260827100000_startup_read_optimization.sql',
  '20260828120000_strain_v2_shadow.sql',
  '20260830202224_day_completeness.sql',
  '20260830202241_overnight_finalization.sql',
  '20260830202255_day_completeness_harden.sql',
  '20260830204525_day_completeness_revoke_truncate.sql',
  '20260830213940_gap_expected_absence.sql',
  '20260830230000_sleep_projection_day_ownership.sql',
  '20260830260000_steps_recompute_clear.sql',
  '20260830270000_apple_watch_step_reference_labels.sql',
  '20260830280000_steps_v3_reference_hardening.sql',
  '20260831024452_steps_v3_reference_hardening.sql',
  '20260831030000_steps_v3_reference_hardening.sql',
  '20260831033637_engine_patch_service_role.sql',
  '20260831081315_steps_v3_read_auth_and_label_invariants.sql',
  '20260831224500_day_snapshot_available_sources.sql',
  '20260901002700_canonical_snapshot_availability.sql',
  '20260901004753_snapshot_energy_steps_contract.sql',
  '20260901010629_sleep_persist_state.sql',
  '20260901010751_sleep_persist_state_rpcs.sql',
  '20260901012423_database_security_hardening.sql',
  '20260901022006_snapshot_hr_occupied_buckets.sql',
  '20260901022058_snapshot_hr_occupied_coverage.sql',
  '20260901204500_skin_temp_display.sql',
  '20260902010000_sleep_stager_v3_shadow.sql',
  '20260902120000_sleep_stager_v3_shadow_rpc.sql',
  '20260902130000_workout_detect_v2_beta.sql',
  '20260902140000_snapshot_persisted_metrics.sql',
  '20260902220000_shadow_read_model_snapshot.sql',
  '20260907133000_noop_hr_samples.sql',
  '20260907133100_noop_append_stream_projections.sql',
  '20260907140000_noop_ingest_tokens.sql',
  '20260907150000_noop_push_wal.sql',
  '20260907160000_noop_journal_entries.sql',
  '20260907170000_noop_raw_object_lane.sql',
  '20260908120000_noop_push_staging_parts.sql',
  '20260911120000_noop_remaining_append_projections.sql',
  '20260911140000_scheduled_workers_pg_cron.sql',
  '20260911160000_fix_http_post_worker.sql',
  '20260911170000_http_post_worker_timeout.sql',
  '20260916160000_scoring_service_state.sql',
  '20260916170000_scoring_work_items_device_id.sql',
  '20260917180000_server_score_user_reads.sql',
  '20260917190000_scoring_derived_artifact.sql',
  '20260918010000_production_scoring_durability.sql',
  '20260918020000_production_intake_durability.sql',
  '20260918030000_production_scoring_review_repairs.sql',
  '20260918040000_production_projection_debt.sql',
  '20260918050000_production_scoring_history.sql',
  '20260918060000_production_scalar_projections.sql',
  '20260918070000_production_aux_identity_provenance.sql',
  '20260918080000_production_ppg_input_selection.sql',
]);
const basenameIDs = new Map(SUPPORTED_LEDGER_BASENAMES.map(name => [name, name.slice(0, 14)]));

export function canonicalMigrationLedger(raw) {
  requireThat(Array.isArray(raw), 'raw migration ledger must be an array');
  const canonical = raw.map(value => {
    requireThat(typeof value === 'string', 'raw migration ledger entries must be strings');
    if (value.length === 14 && /^\d{14}$/.test(value)) return value;
    requireThat(basenameIDs.has(value), 'unsupported migration ledger basename');
    return basenameIDs.get(value);
  });
  // Detect duplicate canonical IDs even when their raw representations differ.
  migrationLedger(canonical);
  return canonical.sort();
}

export function validateMigrationEvidence(server) {
  migrationLedger(server?.migrations); // Evidence IDs remain canonical, never basenames.
  const canonical = canonicalMigrationLedger(server?.migrationLedgerRaw);
  requireThat(JSON.stringify(canonical) === JSON.stringify([...server.migrations].sort()),
    'recorded raw migration ledger differs from canonical evidence IDs');
  return canonical;
}
