BEGIN;
SET ROLE wo_owner;
-- P3: persist the window/delay flags that the public metric contract requires. P2 stored only
-- value/start/end/source/reason; the flags existed solely inside compute_metrics output.
ALTER TABLE wo_v2.current_metrics ADD COLUMN window_adjusted boolean NOT NULL DEFAULT false;
ALTER TABLE wo_v2.current_metrics ADD COLUMN delayed boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN wo_v2.current_metrics.window_adjusted IS '区间是否被实际披露边界调整（非请求的标准窗口）';
COMMENT ON COLUMN wo_v2.current_metrics.delayed IS '区间终点之后是否已有应披露而未到账的日期（披露滞后）';

CREATE OR REPLACE FUNCTION wo_v2.recalculate(target uuid,as_of date) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM inclusion_reasons WHERE share_id=target) THEN
   INSERT INTO current_metrics(share_id,metric_code,value,start_date,end_date,source_id,unavailable_reason,window_adjusted,delayed)
   SELECT target,item->>'metricCode',(item->>'value')::numeric,(item->>'startDate')::date,(item->>'endDate')::date,item->>'sourceId',item->>'unavailableReason',
     COALESCE((item->>'windowAdjusted')::boolean,false),COALESCE((item->>'delayed')::boolean,false)
   FROM jsonb_array_elements(compute_metrics(target,as_of)) item
   ON CONFLICT(share_id,metric_code) DO UPDATE SET value=excluded.value,start_date=excluded.start_date,end_date=excluded.end_date,source_id=excluded.source_id,
     unavailable_reason=excluded.unavailable_reason,window_adjusted=excluded.window_adjusted,delayed=excluded.delayed;
 END IF;
END $$;
RESET ROLE;
COMMIT;
