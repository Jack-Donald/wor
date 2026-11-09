BEGIN;
SET ROLE wo_owner;
-- P3: restricted catalog maintenance. Maintainer-only, idempotent by proven business keys
-- (registration code / manager+product code / share code / source-scoped external identifiers).
-- Never merges by name, never writes inclusion reasons, facts or metrics, never rewrites
-- catalog timestamps when nothing changed. Each item is atomic: a rejected item rolls back
-- its own writes (custom errcode WO010 stays inside this function).
CREATE FUNCTION wo_rpc.wo_catalog_sync_v1(payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,wo_v2,pg_temp AS $$
DECLARE item jsonb; idx integer:=0; src text; results jsonb:='[]'::jsonb;
 prod products%ROWTYPE; share_row shares%ROWTYPE; product_id_value uuid; share_id_value uuid;
 action text; reason text; offerings_added integer:=0; off jsonb; ext jsonb; ext_target uuid;
 existing_ext external_identifiers%ROWTYPE; default_share boolean; state text;
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
     FOR ext IN SELECT value FROM jsonb_array_elements(item->'externalIds') WHERE value->>'kind' LIKE 'share:%' LOOP
       EXIT WHEN share_id_value IS NOT NULL;
       SELECT ext.share_id INTO share_id_value FROM external_identifiers ext WHERE ext.source_id=src AND ext.kind=ext.kind AND ext.value=ext.value;
     END LOOP;
     IF share_id_value IS NULL AND item->>'shareCode' IS NOT NULL THEN
       SELECT id INTO share_id_value FROM shares WHERE product_id=prod.id AND share_code=item->>'shareCode';
     END IF;
     IF share_id_value IS NULL THEN
       SELECT NOT EXISTS(SELECT 1 FROM shares WHERE product_id=prod.id) INTO default_share;
       INSERT INTO shares(product_id,name,share_code,is_default,inception_date,lifecycle_state,operating_mode,restriction_days,collection_capability)
       VALUES(prod.id,item->>'shareName',item->>'shareCode',default_share,(item->>'inceptionDate')::date,item->>'lifecycleState',
         COALESCE(item->>'operatingMode','open'),COALESCE((item->>'restrictionDays')::integer,0),COALESCE(item->>'collectionCapability','unknown'))
       RETURNING * INTO share_row;
       share_id_value:=share_row.id;
       IF action='unchanged' THEN action:='created'; END IF;
     ELSE
       UPDATE shares SET name=item->>'shareName',inception_date=(item->>'inceptionDate')::date,lifecycle_state=item->>'lifecycleState',
         operating_mode=COALESCE(item->>'operatingMode','open'),restriction_days=COALESCE((item->>'restrictionDays')::integer,0),
         collection_capability=COALESCE(item->>'collectionCapability','unknown')
       WHERE id=share_id_value AND (name,inception_date,lifecycle_state,operating_mode,restriction_days,collection_capability) IS DISTINCT FROM
         (item->>'shareName',(item->>'inceptionDate')::date,item->>'lifecycleState',COALESCE(item->>'operatingMode','open'),COALESCE((item->>'restrictionDays')::integer,0),COALESCE(item->>'collectionCapability','unknown'));
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
