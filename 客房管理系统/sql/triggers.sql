-- ============================================================
-- 客房管理系统 - 数据库触发器
-- ============================================================
-- 说明：
--     1. 办理入住 → 自动计算房费、积分抵扣、押金、积分赠送、会员升级
--     2. 办理退房 → 自动处理押金抵扣、损坏赔偿、押金退还、积分赠送
--     3. 续住     → 自动计算续住房费、积分抵扣、积分赠送
--     4. 换房     → 自动更新房间状态、记录换房历史
--     5. 房型升级 → 自动计算升级差价、积分抵扣、积分赠送
--     6. 增值服务 → 自动记录消费、赠送积分
--     7. 杂项消费 → 自动赠送积分
--     8. 维修清洁 → 自动更新房间状态
--     9. 预订取消 → 自动恢复剩余房间数
--    10. 客户注册 → 默认密码、积分校验兜底
--    11. 客户更新 → 积分≥3000 自动升级会员
-- 执行方式：
--   mysql -u root -p --default-character-set=utf8mb4 < triggers.sql
-- ============================================================

USE hotel_management;

DROP TRIGGER IF EXISTS trg_checkin_before_insert;
DROP TRIGGER IF EXISTS trg_checkin_insert;
DROP TRIGGER IF EXISTS trg_checkout_insert;
DROP TRIGGER IF EXISTS trg_checkin_update;
DROP TRIGGER IF EXISTS trg_pool_service_insert;
DROP TRIGGER IF EXISTS trg_gym_service_insert;
DROP TRIGGER IF EXISTS trg_dining_service_insert;
DROP TRIGGER IF EXISTS trg_consumption_insert;
DROP TRIGGER IF EXISTS trg_room_service_insert;
DROP TRIGGER IF EXISTS trg_booking_update;
DROP TRIGGER IF EXISTS trg_customer_update;
DROP TRIGGER IF EXISTS trg_customer_insert;

DELIMITER $$

-- ============================================================
-- 触发器1a：办理入住（BEFORE INSERT）— 自动关联预订
-- 触发时机：向 check_in 表插入记录前
-- 业务逻辑：如未指定 booking_id，自动查找该客户的"已预订"记录并关联
-- ============================================================
CREATE TRIGGER trg_checkin_before_insert
BEFORE INSERT ON check_in
FOR EACH ROW
BEGIN
    IF NEW.booking_id IS NULL THEN
        SELECT booking_id INTO @auto_bid FROM booking
        WHERE customer_id = NEW.customer_id AND status = '已预订'
        ORDER BY booking_time ASC LIMIT 1;
        IF @auto_bid IS NOT NULL THEN
            SET NEW.booking_id = @auto_bid;
        END IF;
    END IF;
END$$

-- ============================================================
-- 触发器1b：办理入住（AFTER INSERT）
-- 触发时机：向 check_in 表插入记录后
-- 业务逻辑：
--   ① 计算入住天数和房费（会员享 9 折）
--   ② 自动使用积分抵扣（100积分=1元，用尽可用积分）
--   ③ 自动计算押金（房价≥600 → 1000元，其余 → 500元）
--   ④ 写入消费记录（房费、积分抵扣、押金）
--   ⑤ 赠送积分（按实付房费：普通1倍，会员1.5倍）
--   ⑥ 更新客房状态为"已入住"
--   ⑦ 更新预订状态为"已入住"（booking_id 由 BEFORE 触发器自动关联）
--   ⑧ 检查累计消费是否达到会员升级标准（≥3000元）
-- ============================================================
CREATE TRIGGER trg_checkin_insert
AFTER INSERT ON check_in
FOR EACH ROW
BEGIN
    DECLARE v_price DECIMAL(10,2);
    DECLARE v_member_level VARCHAR(10);
    DECLARE v_points INT;
    DECLARE v_stay_days INT;
    DECLARE v_room_fee DECIMAL(10,2);
    DECLARE v_member_discount DECIMAL(10,2) DEFAULT 0;
    DECLARE v_points_used INT DEFAULT 0;
    DECLARE v_points_deduct DECIMAL(10,2) DEFAULT 0;
    DECLARE v_points_earned INT DEFAULT 0;
    DECLARE v_multiplier DECIMAL(3,1) DEFAULT 1.0;
    DECLARE v_deposit DECIMAL(10,2);
    DECLARE v_total_spent DECIMAL(10,2) DEFAULT 0;

    -- 查询房间价格
    SELECT price INTO v_price FROM room WHERE room_id = NEW.room_id;

    -- 查询客户会员等级和积分
    SELECT member_level, points INTO v_member_level, v_points
    FROM customer WHERE customer_id = NEW.customer_id;

    -- 计算入住天数
    SET v_stay_days = GREATEST(1, DATEDIFF(DATE(NEW.expected_checkout), CURDATE()));

    -- 计算房费：天数 × 单价
    SET v_room_fee = ROUND(v_price * v_stay_days, 2);

    -- 会员 9 折
    IF v_member_level = '会员' THEN
        SET v_member_discount = ROUND(v_room_fee * 0.1, 2);
        SET v_room_fee = ROUND(v_room_fee * 0.9, 2);
    END IF;

    -- 自动积分抵扣：最大可用 = MIN(可用积分, 房费×100)
    IF v_points > 0 AND v_room_fee > 0 THEN
        SET v_points_used = LEAST(v_points, FLOOR(v_room_fee * 100));
        IF v_points_used > 0 THEN
            SET v_points_deduct = ROUND(v_points_used / 100.0, 2);
            IF v_points_deduct > v_room_fee THEN
                SET v_points_deduct = ROUND(v_room_fee, 2);
                SET v_points_used = FLOOR(v_room_fee * 100);
            END IF;
            SET v_room_fee = ROUND(v_room_fee - v_points_deduct, 2);
        END IF;
    END IF;

    -- 自动押金：套房(≥600元) 1000元，其他 500元
    IF v_price >= 600 THEN
        SET v_deposit = 1000.00;
    ELSE
        SET v_deposit = 500.00;
    END IF;

    -- ① 写入房费消费记录
    INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
    VALUES (NEW.checkin_id, '房费', v_room_fee, NEW.operator_id,
            CONCAT(v_stay_days, '天 ', v_price, '元',
                   IF(v_member_level='会员', ' 会员9折', ''),
                   IF(v_points_deduct>0, CONCAT(' 积分抵扣', v_points_deduct, '元'), '')));

    -- ② 积分抵扣：更新客户积分 + 写入积分流水
    IF v_points_used > 0 THEN
        INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
        VALUES (NEW.checkin_id, '积分抵扣', v_points_deduct, NEW.operator_id,
                CONCAT('使用', v_points_used, '积分'));
        UPDATE customer SET points = points - v_points_used
        WHERE customer_id = NEW.customer_id;
        INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                   source_id, amount, balance_after, remark)
        VALUES (NEW.customer_id, '使用', -v_points_used, '积分抵扣', NEW.checkin_id,
                v_points_deduct,
                (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                CONCAT('入住#', NEW.checkin_id, '抵扣'));
    END IF;

    -- ③ 写入押金消费记录
    INSERT INTO consumption (checkin_id, item_name, amount, operator_id)
    VALUES (NEW.checkin_id, '入住押金', v_deposit, NEW.operator_id);

    -- ④ 赠送积分（按实付房费）
    IF v_member_level = '会员' THEN
        SET v_multiplier = 1.5;
    ELSE
        SET v_multiplier = 1.0;
    END IF;
    SET v_points_earned = FLOOR(v_room_fee * v_multiplier);
    IF v_points_earned > 0 THEN
        UPDATE customer SET points = points + v_points_earned
        WHERE customer_id = NEW.customer_id;
        INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                   source_id, amount, balance_after, remark)
        VALUES (NEW.customer_id, '获得', v_points_earned, '入住结算', NEW.checkin_id,
                v_room_fee,
                (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                CONCAT('入住#', NEW.checkin_id, ' 倍率', v_multiplier));
    END IF;

    -- ⑤ 更新客房状态
    UPDATE room SET status = '已入住' WHERE room_id = NEW.room_id;
    -- ⑥ 更新预订状态（booking_id 由 BEFORE 触发器自动关联）
    IF NEW.booking_id IS NOT NULL THEN
        UPDATE booking SET status = '已入住' WHERE booking_id = NEW.booking_id;
    END IF;

    -- ⑦ 检查会员升级（累计消费 ≥ 3000元，排除押金和积分抵扣）
    IF v_member_level = '普通' THEN
        SELECT COALESCE(SUM(c.amount), 0) INTO v_total_spent
        FROM consumption c
        JOIN check_in ci ON c.checkin_id = ci.checkin_id
        WHERE ci.customer_id = NEW.customer_id
          AND c.item_name NOT IN ('入住押金', '积分抵扣');
        IF v_total_spent >= 3000 THEN
            UPDATE customer SET member_level = '会员'
            WHERE customer_id = NEW.customer_id;
        END IF;
    END IF;
END$$

-- ============================================================
-- 触发器2：办理退房
-- 触发时机：向 check_out 表插入记录前
-- 业务逻辑：
--   ① 查询该入住的所有押金
--   ② 损坏赔偿优先从押金扣除，超出部分生成补交金额
--   ③ 退还剩余押金（如有）
--   ④ 更新房间状态为"清洁中"
--   ⑤ 更新入住状态为"已退房"
-- ============================================================
CREATE TRIGGER trg_checkout_insert
BEFORE INSERT ON check_out
FOR EACH ROW
BEGIN
    DECLARE v_deposit DECIMAL(10,2) DEFAULT 0;
    DECLARE v_deposit_deduct DECIMAL(10,2) DEFAULT 0;
    DECLARE v_extra_pay DECIMAL(10,2) DEFAULT 0;

    SELECT COALESCE(SUM(amount), 0) INTO v_deposit
    FROM consumption
    WHERE checkin_id = NEW.checkin_id AND item_name = '入住押金';

    IF NEW.damage_fee > v_deposit THEN
        SET v_deposit_deduct = v_deposit;
        SET v_extra_pay = NEW.damage_fee - v_deposit;
    ELSE
        SET v_deposit_deduct = NEW.damage_fee;
        SET v_extra_pay = 0;
    END IF;

    SET NEW.deposit_deduct = v_deposit_deduct;
    SET NEW.extra_pay = v_extra_pay;

    IF v_deposit > v_deposit_deduct THEN
        INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
        VALUES (NEW.checkin_id, '押金退还', v_deposit - v_deposit_deduct, NEW.operator_id,
                CONCAT('押金退还 ', v_deposit, '-', v_deposit_deduct));
    END IF;

    UPDATE room r
    JOIN check_in ci ON ci.room_id = r.room_id
    SET r.status = '清洁中'
    WHERE ci.checkin_id = NEW.checkin_id;

    UPDATE check_in SET status = '已退房' WHERE checkin_id = NEW.checkin_id;
END$$

-- ============================================================
-- 触发器3：续住/换房/升级（三合一）
-- 触发时机：更新 check_in 表时
-- 业务逻辑：
--   ① 续住（expected_checkout 改变）：计算续住房费、积分抵扣、积分赠送
--   ② 换房（room_id 改变，新房价 <= 旧房价）：更新房间状态、记录换房历史
--   ③ 升级（room_id 改变，新房价 > 旧房价）：计算升级差价、积分抵扣、积分赠送
-- ============================================================
CREATE TRIGGER trg_checkin_update
AFTER UPDATE ON check_in
FOR EACH ROW
BEGIN
    DECLARE v_old_price DECIMAL(10,2);
    DECLARE v_new_price DECIMAL(10,2);
    DECLARE v_member_level VARCHAR(10);
    DECLARE v_points INT;
    DECLARE v_points_used INT DEFAULT 0;
    DECLARE v_points_deduct DECIMAL(10,2) DEFAULT 0;
    DECLARE v_points_earned INT DEFAULT 0;
    DECLARE v_multiplier DECIMAL(3,1) DEFAULT 1.0;
    DECLARE v_extra_days INT;
    DECLARE v_extra_fee DECIMAL(10,2);
    DECLARE v_member_discount DECIMAL(10,2) DEFAULT 0;
    DECLARE v_remain_days INT;
    DECLARE v_upgrade_diff DECIMAL(10,2);
    DECLARE v_upgrade_total DECIMAL(10,2);
    DECLARE v_paid_amount DECIMAL(10,2);

    IF NEW.status = '入住中' THEN

        -- 场景1：续住 — expected_checkout 改变
        IF NEW.expected_checkout <> OLD.expected_checkout THEN
            SELECT price INTO v_new_price FROM room WHERE room_id = NEW.room_id;
            SET v_extra_days = GREATEST(1, DATEDIFF(DATE(NEW.expected_checkout), DATE(OLD.expected_checkout)));
            SET v_extra_fee = ROUND(v_new_price * v_extra_days, 2);

            SELECT member_level, points INTO v_member_level, v_points
            FROM customer WHERE customer_id = NEW.customer_id;

            IF v_member_level = '会员' THEN
                SET v_member_discount = ROUND(v_extra_fee * 0.1, 2);
                SET v_extra_fee = ROUND(v_extra_fee * 0.9, 2);
            END IF;

            IF v_points > 0 AND v_extra_fee > 0 THEN
                SET v_points_used = LEAST(v_points, FLOOR(v_extra_fee * 100));
                IF v_points_used > 0 THEN
                    SET v_points_deduct = ROUND(v_points_used / 100.0, 2);
                    IF v_points_deduct > v_extra_fee THEN
                        SET v_points_deduct = ROUND(v_extra_fee, 2);
                        SET v_points_used = FLOOR(v_extra_fee * 100);
                    END IF;
                    SET v_extra_fee = ROUND(v_extra_fee - v_points_deduct, 2);
                END IF;
            END IF;

            INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
            VALUES (NEW.checkin_id, '续住房费', v_extra_fee, NEW.operator_id,
                    CONCAT('续住', v_extra_days, '天 ', v_new_price, '元/天',
                           IF(v_member_level='会员', ' 会员9折', ''),
                           IF(v_points_deduct>0, CONCAT(' 积分抵扣', v_points_deduct, '元'), '')));

            IF v_points_used > 0 THEN
                INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
                VALUES (NEW.checkin_id, '积分抵扣', v_points_deduct, NEW.operator_id,
                        CONCAT('续住使用', v_points_used, '积分'));
                UPDATE customer SET points = points - v_points_used
                WHERE customer_id = NEW.customer_id;
                INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                           source_id, amount, balance_after, remark)
                VALUES (NEW.customer_id, '使用', -v_points_used, '积分抵扣', NEW.checkin_id,
                        v_points_deduct,
                        (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                        CONCAT('续住#', NEW.checkin_id, '抵扣'));
            END IF;

            IF v_member_level = '会员' THEN SET v_multiplier = 1.5; ELSE SET v_multiplier = 1.0; END IF;
            SET v_points_earned = FLOOR(v_extra_fee * v_multiplier);
            IF v_points_earned > 0 THEN
                UPDATE customer SET points = points + v_points_earned
                WHERE customer_id = NEW.customer_id;
                INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                           source_id, amount, balance_after, remark)
                VALUES (NEW.customer_id, '获得', v_points_earned, '续住结算', NEW.checkin_id,
                        v_extra_fee,
                        (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                        CONCAT('续住#', NEW.checkin_id, ' 倍率', v_multiplier));
            END IF;
        END IF;

        -- 场景2：换房/升级 — room_id 改变
        IF NEW.room_id <> OLD.room_id THEN
            SELECT price INTO v_old_price FROM room WHERE room_id = OLD.room_id;
            SELECT price INTO v_new_price FROM room WHERE room_id = NEW.room_id;

            -- 根据是否有具体原因决定旧房间状态：有原因→维修中，无原因→空闲
            IF @room_change_reason IS NOT NULL AND @room_change_reason <> '' THEN
                UPDATE room SET status = '维修中' WHERE room_id = OLD.room_id;
                INSERT INTO room_service (room_id, service_type, description, operator_id)
                VALUES (OLD.room_id, '维修', @room_change_reason, NEW.operator_id);
            ELSE
                UPDATE room SET status = '空闲' WHERE room_id = OLD.room_id;
            END IF;
            UPDATE room SET status = '已入住' WHERE room_id = NEW.room_id;

            INSERT INTO room_change (checkin_id, old_room_id, new_room_id, reason, operator_id)
            VALUES (NEW.checkin_id, OLD.room_id, NEW.room_id,
                    COALESCE(@room_change_reason, '前台换房'), NEW.operator_id);

            IF v_new_price > v_old_price THEN
                SELECT member_level, points INTO v_member_level, v_points
                FROM customer WHERE customer_id = NEW.customer_id;

                SET v_remain_days = GREATEST(1, DATEDIFF(DATE(NEW.expected_checkout), CURDATE()));
                SET v_upgrade_diff = v_new_price - v_old_price;
                SET v_upgrade_total = ROUND(v_upgrade_diff * v_remain_days, 2);

                IF v_member_level = '会员' THEN
                    SET v_upgrade_total = ROUND(v_upgrade_total * 0.8, 2);
                END IF;

                SET v_points_used = 0;
                SET v_points_deduct = 0;
                IF v_member_level = '会员' AND v_points > 0 AND v_upgrade_total > 0 THEN
                    SET v_points_used = LEAST(v_points, FLOOR(v_upgrade_total * 100));
                    IF v_points_used > 0 THEN
                        SET v_points_deduct = ROUND(v_points_used / 100.0, 2);
                        IF v_points_deduct > v_upgrade_total THEN
                            SET v_points_deduct = ROUND(v_upgrade_total, 2);
                            SET v_points_used = FLOOR(v_upgrade_total * 100);
                        END IF;
                        SET v_upgrade_total = ROUND(v_upgrade_total - v_points_deduct, 2);
                    END IF;
                END IF;

                SET v_paid_amount = v_upgrade_total;

                INSERT INTO room_upgrade (checkin_id, customer_id, old_room_id, new_room_id,
                    old_price, new_price, remain_days, points_used, paid_amount, operator_id)
                VALUES (NEW.checkin_id, NEW.customer_id, OLD.room_id, NEW.room_id,
                    v_old_price, v_new_price, v_remain_days, v_points_used, v_paid_amount, NEW.operator_id);

                INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
                VALUES (NEW.checkin_id, '房型升级费', v_paid_amount, NEW.operator_id,
                        CONCAT('升级 ', OLD.room_id, '->', NEW.room_id, ' ',
                               v_remain_days, '天 ', v_upgrade_diff, '元/天',
                               IF(v_member_level='会员', ' 会员8折', ''),
                               IF(v_points_deduct>0, CONCAT(' 积分抵扣', v_points_deduct, '元'), '')));

                IF v_points_used > 0 THEN
                    INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
                    VALUES (NEW.checkin_id, '积分抵扣', v_points_deduct, NEW.operator_id,
                            CONCAT('升级使用', v_points_used, '积分'));
                    UPDATE customer SET points = points - v_points_used
                    WHERE customer_id = NEW.customer_id;
                    INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                               source_id, amount, balance_after, remark)
                    VALUES (NEW.customer_id, '使用', -v_points_used, '积分抵扣', NEW.checkin_id,
                            v_points_deduct,
                            (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                            CONCAT('升级#', NEW.checkin_id, '抵扣'));
                END IF;

                IF v_member_level = '会员' THEN SET v_multiplier = 1.5; ELSE SET v_multiplier = 1.0; END IF;
                SET v_points_earned = FLOOR(v_paid_amount * v_multiplier);
                IF v_points_earned > 0 THEN
                    UPDATE customer SET points = points + v_points_earned
                    WHERE customer_id = NEW.customer_id;
                    INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                               source_id, amount, balance_after, remark)
                    VALUES (NEW.customer_id, '获得', v_points_earned, '房型升级', NEW.checkin_id,
                            v_paid_amount,
                            (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                            CONCAT('升级#', NEW.checkin_id, ' 倍率', v_multiplier));
                END IF;
            END IF;
        END IF;

    END IF;
END$$

-- ============================================================
-- 触发器4：游泳池服务
-- ============================================================
CREATE TRIGGER trg_pool_service_insert
AFTER INSERT ON pool_service
FOR EACH ROW
BEGIN
    DECLARE v_member_level VARCHAR(10);
    DECLARE v_multiplier DECIMAL(3,1) DEFAULT 1.0;
    DECLARE v_points_earned INT DEFAULT 0;

    INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
    VALUES (NEW.checkin_id, '游泳池', NEW.cost, NEW.operator_id,
            CONCAT('使用', NEW.use_num, '次'));

    SELECT member_level INTO v_member_level FROM customer WHERE customer_id = NEW.customer_id;
    IF v_member_level = '会员' THEN SET v_multiplier = 1.5; END IF;
    SET v_points_earned = FLOOR(NEW.cost * v_multiplier);
    IF v_points_earned > 0 THEN
        UPDATE customer SET points = points + v_points_earned WHERE customer_id = NEW.customer_id;
        INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                   source_id, amount, balance_after, remark)
        VALUES (NEW.customer_id, '获得', v_points_earned, '泳池消费', NEW.pool_id,
                NEW.cost,
                (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                CONCAT('泳池#', NEW.pool_id, ' 倍率', v_multiplier));
    END IF;
END$$

-- ============================================================
-- 触发器5：健身房服务
-- ============================================================
CREATE TRIGGER trg_gym_service_insert
AFTER INSERT ON gym_service
FOR EACH ROW
BEGIN
    DECLARE v_member_level VARCHAR(10);
    DECLARE v_multiplier DECIMAL(3,1) DEFAULT 1.0;
    DECLARE v_points_earned INT DEFAULT 0;

    INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
    VALUES (NEW.checkin_id, '健身房', NEW.cost, NEW.operator_id,
            CONCAT('使用', NEW.use_num, '次'));

    SELECT member_level INTO v_member_level FROM customer WHERE customer_id = NEW.customer_id;
    IF v_member_level = '会员' THEN SET v_multiplier = 1.5; END IF;
    SET v_points_earned = FLOOR(NEW.cost * v_multiplier);
    IF v_points_earned > 0 THEN
        UPDATE customer SET points = points + v_points_earned WHERE customer_id = NEW.customer_id;
        INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                   source_id, amount, balance_after, remark)
        VALUES (NEW.customer_id, '获得', v_points_earned, '健身房消费', NEW.gym_id,
                NEW.cost,
                (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                CONCAT('健身房#', NEW.gym_id, ' 倍率', v_multiplier));
    END IF;
END$$

-- ============================================================
-- 触发器6：餐厅服务
-- ============================================================
CREATE TRIGGER trg_dining_service_insert
AFTER INSERT ON dining_service
FOR EACH ROW
BEGIN
    DECLARE v_member_level VARCHAR(10);
    DECLARE v_multiplier DECIMAL(3,1) DEFAULT 1.0;
    DECLARE v_points_earned INT DEFAULT 0;

    INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark)
    VALUES (NEW.checkin_id, '餐厅', NEW.total_cost, NEW.operator_id,
            CONCAT(NEW.diner_num, '人就餐'));

    SELECT member_level INTO v_member_level FROM customer WHERE customer_id = NEW.customer_id;
    IF v_member_level = '会员' THEN SET v_multiplier = 1.5; END IF;
    SET v_points_earned = FLOOR(NEW.total_cost * v_multiplier);
    IF v_points_earned > 0 THEN
        UPDATE customer SET points = points + v_points_earned WHERE customer_id = NEW.customer_id;
        INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                   source_id, amount, balance_after, remark)
        VALUES (NEW.customer_id, '获得', v_points_earned, '餐厅消费', NEW.dining_id,
                NEW.total_cost,
                (SELECT points FROM customer WHERE customer_id = NEW.customer_id),
                CONCAT('餐厅#', NEW.dining_id, ' 倍率', v_multiplier));
    END IF;
END$$

-- ============================================================
-- 触发器7：杂项消费 -> 自动赠送积分
-- ============================================================
CREATE TRIGGER trg_consumption_insert
AFTER INSERT ON consumption
FOR EACH ROW
BEGIN
    DECLARE v_customer_id INT;
    DECLARE v_member_level VARCHAR(10);
    DECLARE v_multiplier DECIMAL(3,1) DEFAULT 1.0;
    DECLARE v_points_earned INT DEFAULT 0;

    IF NEW.item_name NOT IN ('房费', '续住房费', '房型升级费', '入住押金', '押金退还',
                              '积分抵扣', '游泳池', '健身房', '餐厅') THEN
        SELECT ci.customer_id, cu.member_level
        INTO v_customer_id, v_member_level
        FROM check_in ci
        JOIN customer cu ON ci.customer_id = cu.customer_id
        WHERE ci.checkin_id = NEW.checkin_id;

        IF v_member_level = '会员' THEN SET v_multiplier = 1.5; END IF;
        SET v_points_earned = FLOOR(NEW.amount * v_multiplier);

        IF v_points_earned > 0 THEN
            UPDATE customer SET points = points + v_points_earned
            WHERE customer_id = v_customer_id;
            INSERT INTO points_record (customer_id, change_type, points_change, source_type,
                                       source_id, amount, balance_after, remark)
            VALUES (v_customer_id, '获得', v_points_earned, '杂项消费', NEW.consumption_id,
                    NEW.amount,
                    (SELECT points FROM customer WHERE customer_id = v_customer_id),
                    CONCAT('杂项#', NEW.consumption_id, ' 倍率', v_multiplier));
        END IF;
    END IF;
END$$

-- ============================================================
-- 触发器8：维修/清洁 -> 自动更新房间状态
-- ============================================================
CREATE TRIGGER trg_room_service_insert
AFTER INSERT ON room_service
FOR EACH ROW
BEGIN
    IF NEW.service_type = '维修' THEN
        UPDATE room SET status = '维修中' WHERE room_id = NEW.room_id;
    ELSEIF NEW.service_type = '清洁' THEN
        UPDATE room SET status = '清洁中' WHERE room_id = NEW.room_id;
    END IF;
END$$

-- ============================================================
-- 触发器9：预订取消 -> 恢复剩余房间数
-- ============================================================
CREATE TRIGGER trg_booking_update
AFTER UPDATE ON booking
FOR EACH ROW
BEGIN
    IF NEW.status = '已取消' AND OLD.status <> '已取消' THEN
        UPDATE room_type SET surplus_room = surplus_room + OLD.room_count
        WHERE type_id = OLD.type_id;
    END IF;
END$$

-- ============================================================
-- 触发器10：客户注册 -> 默认密码 + 积分校验兜底
-- ============================================================
CREATE TRIGGER trg_customer_insert
BEFORE INSERT ON customer
FOR EACH ROW
BEGIN
    IF NEW.password IS NULL OR NEW.password = '' THEN
        SET NEW.password = '123456';
    END IF;
    IF NEW.points < 0 THEN
        SET NEW.points = 0;
    END IF;
END$$

-- ============================================================
-- 触发器11：客户信息更新 -> 自动会员升级
-- 触发时机：更新 customer 表时
-- 业务逻辑：积分 ≥ 3000 自动升级为会员
-- ============================================================
CREATE TRIGGER trg_customer_update
BEFORE UPDATE ON customer
FOR EACH ROW
BEGIN
    IF NEW.points >= 3000 AND OLD.member_level = '普通' AND NEW.member_level = '普通' THEN
        SET NEW.member_level = '会员';
    END IF;
    IF NEW.points < 0 THEN
        SET NEW.points = 0;
    END IF;
END$$

DELIMITER ;
