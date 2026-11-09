BEGIN;
SET ROLE wo_owner;
-- P3: bounded coverage and interior-gap read for planning. Returns actually existing business
-- dates (never only MIN/MAX), consecutive missing disclosure dates inside the requested
-- window, and the calendar due date. Read-only.
CREATE FUNCTION wo_rpc.wo_read_coverage_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE target uuid; src text; max_dates integer; window_from date; window_through date;
 first_date date; last_date date; dates jsonb; rows jsonb; adjustments jsonb; capped boolean:=false; gaps jsonb:='[]'::jsonb;
 day date; gap_start date; gap_end date; result jsonb;
BEGIN
 IF NOT keys_exact(payload,ARRAY['shareId','sourceId','from','through','maxDates'])
   OR (NULLIF(payload->'from','null'::jsonb) IS NOT NULL AND NOT valid_date(payload->>'from'))
   OR (NULLIF(payload->'through','null'::jsonb) IS NOT NULL AND NOT valid_date(payload->>'through'))
   OR jsonb_typeof(payload->'maxDates')<>'number' OR (payload->>'maxDates')::integer NOT BETWEEN 1 AND 800 THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 target:=(payload->>'shareId')::uuid; src:=payload->>'sourceId'; max_dates:=(payload->>'maxDates')::integer;
 PERFORM authorize(src,'daily');
 IF NOT EXISTS(SELECT 1 FROM shares WHERE id=target) THEN RAISE EXCEPTION 'not_found' USING ERRCODE='WO404'; END IF;
 SELECT min(value_date),max(value_date) INTO first_date,last_date FROM observations WHERE share_id=target AND source_id=src;
 window_from:=COALESCE((payload->>'from')::date,first_date);
 window_through:=COALESCE((payload->>'through')::date,GREATEST(last_date,due_date(src,business_today())));
 IF window_from IS NOT NULL AND window_through IS NOT NULL AND window_from>window_through THEN
   result:=window_from; window_from:=window_through; window_through:=result;
 END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('date',value_date,'incomePeriodStart',income_period_start,'incomeBasis',income_basis,
   'unitNav',CASE WHEN unit_nav IS NULL THEN NULL ELSE unit_nav::text END,'cumulativeNav',CASE WHEN cumulative_nav IS NULL THEN NULL ELSE cumulative_nav::text END,
   'incomePer10k',CASE WHEN income_per_10k IS NULL THEN NULL ELSE income_per_10k::text END,'officialYield7d',CASE WHEN official_yield_7d IS NULL THEN NULL ELSE official_yield_7d::text END,
   'adjustmentVerifiedFrom',adjustment_verified_from) ORDER BY value_date),'[]'::jsonb)
 INTO rows FROM (SELECT * FROM observations WHERE share_id=target AND source_id=src ORDER BY value_date DESC LIMIT max_dates) bounded;
 SELECT COALESCE(jsonb_agg(value_date ORDER BY value_date),'[]'::jsonb) INTO dates
   FROM (SELECT value_date FROM observations WHERE share_id=target AND source_id=src
         ORDER BY value_date DESC LIMIT max_dates) bounded_dates;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('date',effective_date,'eventType',event_type,'cashPerUnit',cash_per_unit::text,'splitFactor',split_factor::text) ORDER BY effective_date),'[]'::jsonb)
 INTO adjustments FROM (SELECT * FROM adjustments WHERE share_id=target AND source_id=src ORDER BY effective_date DESC LIMIT max_dates) bounded_adjustments;
 IF first_date IS NOT NULL AND (SELECT count(*) FROM observations WHERE share_id=target AND source_id=src)>max_dates THEN capped:=true; END IF;
 IF window_from IS NOT NULL AND window_through-window_from<=2500 THEN
   FOR day IN SELECT generate_series(window_from,window_through,interval '1 day')::date LOOP
     IF discloses(src,day) AND NOT EXISTS(SELECT 1 FROM observations WHERE share_id=target AND source_id=src AND value_date=day) THEN
       IF gap_start IS NULL THEN gap_start:=day; END IF;
       gap_end:=day;
     ELSIF gap_start IS NOT NULL THEN
       gaps:=gaps||jsonb_build_object('from',gap_start,'through',gap_end); gap_start:=NULL;
     END IF;
   END LOOP;
   IF gap_start IS NOT NULL THEN gaps:=gaps||jsonb_build_object('from',gap_start,'through',gap_end); END IF;
 END IF;
 RETURN jsonb_build_object('shareId',target,'sourceId',src,'first',first_date,'last',last_date,'dates',dates,'rows',rows,'adjustments',adjustments,'capped',capped,'gaps',gaps,
   'windowFrom',window_from,'windowThrough',window_through,'businessToday',business_today(),
   'dueDate',CASE WHEN source_config(src) IS NULL THEN NULL ELSE due_date(src,business_today()) END);
END $$;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_read_coverage_v1(jsonb) TO wo_collector,wo_maintainer;
RESET ROLE;
COMMIT;
