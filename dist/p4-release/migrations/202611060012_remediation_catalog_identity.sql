BEGIN;
SET ROLE wo_owner;
-- P3 整改迁移（复核 F02/F08）：整体替换 wo_catalog_sync_v1，保持入参/出参契约与
-- 202611040007 完全一致。修正点：
-- F02 身份匹配恒真条件：原实现 `WHERE ext.source_id=src AND ext.kind=ext.kind AND
--     ext.value=ext.value` 全部比较的是 SQL 别名列自身（恒真），等于按表中任意第一行
--     决定份额身份，会把不同产品/份额串到同一个 shareId。现改为：把当前输入的外部
--     标识取入 PL/pgSQL 变量（ext_kind/ext_value），按 输入值 匹配，且命中后校验该
--     份额确实属于本次解析出的产品（product_id 归属校验），归属不符按
--     identifier_conflict 拒绝该项，绝不靠任意第一行决定身份。
-- F08 期限未知不再造 0：新建份额时 restriction_days 直接取输入值（可为 NULL，表示
--     未知留待处理），不再 COALESCE 成 0；operating_mode 新建时若无证据（NULL）按
--     invalid_item 拒绝（必须有官方字段依据才能建档），更新时 NULL 表示"本轮无新
--     证据"保留现值，不覆盖为默认值。已核实的 0 与未知自此在数据上可区分。
CREATE OR REPLACE FUNCTION wo_rpc.wo_catalog_sync_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE item jsonb; idx integer:=0; src text; results jsonb:='[]'::jsonb;
 prod products%ROWTYPE; share_row shares%ROWTYPE; product_id_value uuid; share_id_value uuid; matched_product uuid;
 action text; reason text; offerings_added integer:=0; off jsonb; ext jsonb; ext_target uuid;
 ext_kind text; ext_value text; existing_ext external_identifiers%ROWTYPE; default_share boolean; state text;
BEGIN
 IF NOT is_maintainer() THEN RAISE EXCEPTION 'source_forbidden' USING ERRCODE='WO005'; END IF;
 IF NOT keys_exact(payload,ARRAY['protocolVersion','sourceId','items'])
   OR payload->>'protocolVersion' IS DISTINCT FROM 'wo-ingest-v2'
   OR source_config(payload->>'sourceId') IS NULL
   OR jsonb_typeof(payload->'items')<>'array' OR jsonb_array_length(payload->'items')<1 OR jsonb_array_length(payload->'items')>200 THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='WO001'; END IF;
 src:=payload->>'sourceId';
 FOR item IN SELECT value FROM jsonb_array_elements(payload->'items') LOOP
   idx:=idx+1; action:='unchanged'; reason:=NULL; offerings_added:=0; product_id_value:=NULL; share_id_value:=NULL;
   BEGIN
     IF NOT keys_exact(item,ARRAY['registrationCode','productCode','productName','managerName','riskLevel','shareCode','shareName','inceptionDate','lifecycleState','operatingMode','restrictionDays','collectionCapability','offerings','externalIds'])
       OR (NULLIF(item->'registrationCode','null'::jsonb) IS NOT NULL AND (jsonb_typeof(item->'registrationCode')<>'string' OR length(item->>'registrationCode') NOT BETWEEN 1 AND 128))
       OR (NULLIF(item->'productCode','null'::jsonb) IS NOT NULL AND (jsonb_typeof(item->'productCode')<>'string' OR length(item->>'productCode') NOT BETWEEN 1 AND 128))
       OR jsonb_typeof(item->'productName')<>'string' OR length(item->>'productName') NOT BETWEEN 1 AND 300
       OR jsonb_typeof(item->'managerName')<>'string' OR length(item->>'managerName') NOT BETWEEN 1 AND 200
       OR (NULLIF(item->'riskLevel','null'::jsonb) IS NOT NULL AND (jsonb_typeof(item->'riskLevel')<>'string' OR length(item->>'riskLevel') NOT BETWEEN 1 AND 32))
       OR (NULLIF(item->'shareCode','null'::jsonb) IS NOT NULL AND (jsonb_typeof(item->'shareCode')<>'string' OR length(item->>'shareCode') NOT BETWEEN 1 AND 128))
       OR jsonb_typeof(item->'shareName')<>'string' OR length(item->>'shareName') NOT BETWEEN 1 AND 300
       OR (NULLIF(item->'inceptionDate','null'::jsonb) IS NOT NULL AND NOT valid_date(item->>'inceptionDate'))
       OR item->>'lifecycleState' NOT IN ('active','ended','unknown')
       OR (NULLIF(item->'operatingMode','null'::jsonb) IS NOT NULL AND item->>'operatingMode' NOT IN ('open','minimum_holding','closed','periodic','cash_management'))
       OR (NULLIF(item->'restrictionDays','null'::jsonb) IS NOT NULL AND (jsonb_typeof(item->'restrictionDays')<>'number' OR (item->>'restrictionDays')::numeric IS DISTINCT FROM trunc((item->>'restrictionDays')::numeric) OR (item->>'restrictionDays')::integer NOT BETWEEN 0 AND 31))
       OR (NULLIF(item->'collectionCapability','null'::jsonb) IS NOT NULL AND item->>'collectionCapability' NOT IN ('available','unavailable','unknown'))
       OR jsonb_typeof(item->'offerings')<>'array' OR jsonb_array_length(item->'offerings')>64
       OR jsonb_typeof(item->'externalIds')<>'array' OR jsonb_array_length(item->'externalIds')>64
       OR (NULLIF(item->'registrationCode','null'::jsonb) IS NULL AND item->'productCode' IS NULL)
       OR (NULLIF(item->'shareCode','null'::jsonb) IS NULL AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(item->'externalIds') e WHERE e->>'kind' LIKE 'share:%'))
       OR EXISTS(SELECT 1 FROM jsonb_array_elements(item->'offerings') o_item WHERE NOT keys_exact(o_item,ARRAY['channelKey','channelName','salesCode']) OR o_item->>'channelKey' !~ '^[a-z][a-z0-9_-]{0,62}$' OR length(o_item->>'channelName') NOT BETWEEN 1 AND 200 OR (o_item->>'salesCode' IS NOT NULL AND length(o_item->>'salesCode') NOT BETWEEN 1 AND 128))
       OR EXISTS(SELECT 1 FROM jsonb_array_elements(item->'externalIds') e_item WHERE NOT keys_exact(e_item,ARRAY['kind','value']) OR e_item->>'kind' !~ '^(product|share):[a-z][a-z0-9_-]{0,62}$' OR length(e_item->>'value') NOT BETWEEN 1 AND 256) THEN
       RAISE EXCEPTION 'invalid_item' USING ERRCODE='WO010';
     END IF;
     prod:=NULL;
     IF item->>'registrationCode' IS NOT NULL THEN
       SELECT * INTO prod FROM products WHERE registration_code=item->>'registrationCode';
     END IF;
     IF prod.id IS NULL AND item->>'productCode' IS NOT NULL THEN
       SELECT * INTO prod FROM products WHERE manager_name=item->>'managerName' AND product_code=item->>'productCode';
     END IF;
     IF prod.id IS NOT NULL AND prod.manager_name IS DISTINCT FROM item->>'managerName' THEN
       RAISE EXCEPTION 'manager_mismatch' USING ERRCODE='WO010';
     END IF;
     IF prod.id IS NULL THEN
       INSERT INTO products(name,product_code,registration_code,manager_name,risk_level,currency,is_public)
       VALUES(item->>'productName',item->>'productCode',item->>'registrationCode',item->>'managerName',item->>'riskLevel','CNY',true);
       SELECT * INTO prod FROM products
       WHERE (CASE WHEN item->>'registrationCode' IS NOT NULL THEN registration_code=item->>'registrationCode' ELSE manager_name=item->>'managerName' AND product_code=item->>'productCode' END);
       IF prod.id IS NULL THEN RAISE EXCEPTION 'product_conflict' USING ERRCODE='WO010'; END IF;
       action:='created';
     ELSE
       UPDATE products SET name=item->>'productName',risk_level=item->>'riskLevel'
       WHERE id=prod.id AND (name,risk_level) IS DISTINCT FROM (item->>'productName',item->>'riskLevel');
       IF FOUND THEN action:='updated'; prod.name:=item->>'productName'; END IF;
     END IF;
     product_id_value:=prod.id;
     share_id_value:=NULL;
     -- F02：按当前输入的外部标识值匹配既有份额。ext_kind/ext_value 是 PL/pgSQL 变量，
     -- 与表别名 ext 的列明确区分；命中即停止，并对归属做产品一致性校验。
     FOR ext IN SELECT value FROM jsonb_array_elements(item->'externalIds') WHERE value->>'kind' LIKE 'share:%' LOOP
       EXIT WHEN share_id_value IS NOT NULL;
       ext_kind:=ext->>'kind'; ext_value:=ext->>'value';
       SELECT e.share_id INTO share_id_value FROM external_identifiers e
       WHERE e.source_id=src AND e.kind=ext_kind AND e.value=ext_value AND e.share_id IS NOT NULL;
       IF share_id_value IS NOT NULL THEN
         SELECT product_id INTO matched_product FROM shares WHERE id=share_id_value;
         IF matched_product IS DISTINCT FROM product_id_value THEN
           -- 外部标识已指向其他产品下的份额：拒绝本项，不得改写既有归属或串份额
           RAISE EXCEPTION 'identifier_conflict' USING ERRCODE='WO010';
         END IF;
       END IF;
     END LOOP;
     IF share_id_value IS NULL AND item->>'shareCode' IS NOT NULL THEN
       SELECT id INTO share_id_value FROM shares WHERE product_id=prod.id AND share_code=item->>'shareCode';
     END IF;
     IF share_id_value IS NULL THEN
       -- F08：新建份额必须有运作方式证据；期限未知（NULL）原样入库，不造 0。
       IF NULLIF(item->'operatingMode','null'::jsonb) IS NULL THEN
         RAISE EXCEPTION 'operating_mode_required' USING ERRCODE='WO010';
       END IF;
       SELECT NOT EXISTS(SELECT 1 FROM shares WHERE product_id=prod.id) INTO default_share;
       INSERT INTO shares(product_id,name,share_code,is_default,inception_date,lifecycle_state,operating_mode,restriction_days,collection_capability)
       VALUES(prod.id,item->>'shareName',item->>'shareCode',default_share,(item->>'inceptionDate')::date,item->>'lifecycleState',
         item->>'operatingMode',(item->>'restrictionDays')::integer,COALESCE(item->>'collectionCapability','unknown'))
       RETURNING * INTO share_row;
       share_id_value:=share_row.id;
       IF action='unchanged' THEN action:='created'; END IF;
     ELSE
       -- 更新：restrictionDays/operatingMode 为 NULL 表示本轮无新证据，保留现值（IS
       -- DISTINCT FROM 中以现值占位，不写入默认值）。
       UPDATE shares SET name=item->>'shareName',inception_date=(item->>'inceptionDate')::date,lifecycle_state=item->>'lifecycleState',
         operating_mode=COALESCE(item->>'operatingMode',operating_mode),restriction_days=COALESCE((item->>'restrictionDays')::integer,restriction_days),
         collection_capability=COALESCE(item->>'collectionCapability',collection_capability)
       WHERE id=share_id_value AND (name,inception_date,lifecycle_state,operating_mode,restriction_days,collection_capability) IS DISTINCT FROM
         (item->>'shareName',(item->>'inceptionDate')::date,item->>'lifecycleState',COALESCE(item->>'operatingMode',operating_mode),COALESCE((item->>'restrictionDays')::integer,restriction_days),COALESCE(item->>'collectionCapability',collection_capability));
       IF FOUND AND action='unchanged' THEN action:='updated'; END IF;
     END IF;
     FOR off IN SELECT value FROM jsonb_array_elements(item->'offerings') LOOP
       INSERT INTO sales_offerings(share_id,channel_key,channel_name,sales_code)
       VALUES(share_id_value,off->>'channelKey',off->>'channelName',off->>'salesCode')
       ON CONFLICT DO NOTHING;
       IF FOUND THEN offerings_added:=offerings_added+1; END IF;
       UPDATE sales_offerings SET channel_name=off->>'channelName'
       WHERE share_id=share_id_value AND channel_key=off->>'channelKey' AND sales_code IS NOT DISTINCT FROM NULLIF(off->>'salesCode','')
         AND channel_name IS DISTINCT FROM off->>'channelName';
       IF FOUND AND offerings_added=0 AND action='unchanged' THEN action:='updated'; END IF;
     END LOOP;
     IF offerings_added>0 AND action='unchanged' THEN action:='updated'; END IF;
     FOR ext IN SELECT value FROM jsonb_array_elements(item->'externalIds') LOOP
       ext_target:=CASE WHEN ext->>'kind' LIKE 'product:%' THEN product_id_value ELSE share_id_value END;
       SELECT * INTO existing_ext FROM external_identifiers WHERE source_id=src AND kind=ext->>'kind' AND value=ext->>'value';
       IF existing_ext.source_id IS NULL THEN
         INSERT INTO external_identifiers(source_id,kind,value,product_id,share_id)
         VALUES(src,ext->>'kind',ext->>'value',CASE WHEN ext->>'kind' LIKE 'product:%' THEN product_id_value ELSE NULL END,CASE WHEN ext->>'kind' LIKE 'share:%' THEN share_id_value ELSE NULL END);
         IF action='unchanged' THEN action:='updated'; END IF;
       ELSIF existing_ext.product_id IS DISTINCT FROM (CASE WHEN ext->>'kind' LIKE 'product:%' THEN product_id_value ELSE NULL END)
         OR existing_ext.share_id IS DISTINCT FROM (CASE WHEN ext->>'kind' LIKE 'share:%' THEN share_id_value ELSE NULL END) THEN
         RAISE EXCEPTION 'identifier_conflict' USING ERRCODE='WO010';
       END IF;
     END LOOP;
     results:=results||jsonb_build_object('index',idx,'action',action,'reason',NULL,'productId',product_id_value,'shareId',share_id_value,'offeringsAdded',offerings_added);
   EXCEPTION WHEN OTHERS THEN
     GET STACKED DIAGNOSTICS state:=RETURNED_SQLSTATE;
     IF state='WO010' THEN
       results:=results||jsonb_build_object('index',idx,'action','rejected','reason',SQLERRM,'productId',NULL,'shareId',NULL,'offeringsAdded',0);
     ELSE
       RAISE;
     END IF;
   END;
 END LOOP;
 RETURN jsonb_build_object('items',results);
END $$;
GRANT EXECUTE ON FUNCTION wo_rpc.wo_catalog_sync_v1(jsonb) TO wo_maintainer;
RESET ROLE;
COMMIT;
