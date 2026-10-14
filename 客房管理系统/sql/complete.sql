-- ============================================================
-- 客房管理系统 - 完整数据库脚本
-- MySQL 8.0+
-- ============================================================
-- 文件说明：
--   本文件包含完整的数据库定义、测试数据和验证查询。
--   在新电脑上只需执行本文件即可完成全部数据库搭建。
-- 执行方式：
--   mysql -u root -p --default-character-set=utf8mb4 < complete.sql
-- 包含内容：
--   第一部分：数据库与表结构（16张表）
--   第二部分：索引设计（32个索引）
--   第三部分：视图设计（8个视图）
--   第四部分：安全权限设计（3个角色 + 3个用户）
--   第五部分：测试数据
--   第六部分：功能测试查询（25条）
-- ============================================================

-- ============================================================
-- 第一部分：数据库与表结构
-- ============================================================
DROP DATABASE IF EXISTS hotel_management;
CREATE DATABASE hotel_management CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE hotel_management;

-- ---- 1. 客房类别表 ----
CREATE TABLE room_type (
    type_id        INT AUTO_INCREMENT PRIMARY KEY COMMENT '房型编号',
    type_name      VARCHAR(50)   NOT NULL COMMENT '房型名称',
    default_price  DECIMAL(10,2) NOT NULL COMMENT '默认房价',
    total_room     INT           NOT NULL DEFAULT 0,
    surplus_room   INT           NOT NULL DEFAULT 0,
    description    VARCHAR(255)  DEFAULT NULL
) ENGINE=InnoDB COMMENT='客房类别表';

-- ---- 2. 客房信息表 ----
CREATE TABLE room (
    room_id   VARCHAR(10)   PRIMARY KEY COMMENT '客房编号',
    type_id   INT           NOT NULL,
    area      DECIMAL(6,2)  DEFAULT NULL,
    price     DECIMAL(10,2) NOT NULL,
    status    ENUM('空闲','已预订','已入住','清洁中','维修中') NOT NULL DEFAULT '空闲',
    remark    VARCHAR(255)  DEFAULT NULL,
    FOREIGN KEY (type_id) REFERENCES room_type(type_id)
) ENGINE=InnoDB COMMENT='客房信息表';

-- ---- 3. 客户信息表 ----
CREATE TABLE customer (
    customer_id  INT AUTO_INCREMENT PRIMARY KEY,
    name         VARCHAR(50)  NOT NULL,
    gender       ENUM('男','女','其他') DEFAULT '其他',
    phone        VARCHAR(20)  DEFAULT NULL,
    id_card      VARCHAR(18)  DEFAULT NULL,
    password     VARCHAR(255) NOT NULL DEFAULT '123456' COMMENT '客户登录密码',
    member_level ENUM('普通','会员') NOT NULL DEFAULT '普通' COMMENT '会员等级',
    points       INT          NOT NULL DEFAULT 0 COMMENT '可用积分',
    create_time  DATETIME     DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='客户信息表';

-- ---- 4. 系统用户表 ----
CREATE TABLE sys_user (
    user_id   INT AUTO_INCREMENT PRIMARY KEY,
    username  VARCHAR(50)  NOT NULL UNIQUE,
    password  VARCHAR(255) NOT NULL,
    role      ENUM('admin','manager','front') NOT NULL,
    status    TINYINT      NOT NULL DEFAULT 1
) ENGINE=InnoDB COMMENT='系统用户表';

-- ---- 5. 员工信息表 ----
CREATE TABLE staff (
    staff_id   INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(50) NOT NULL,
    gender     ENUM('男','女','其他') DEFAULT NULL,
    phone      VARCHAR(20) DEFAULT NULL,
    post       VARCHAR(20) NOT NULL,
    entry_time DATE         DEFAULT NULL,
    user_id    INT          DEFAULT NULL,
    status     ENUM('在职','离职') NOT NULL DEFAULT '在职',
    FOREIGN KEY (user_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='员工信息表';

-- ---- 6. 预订信息表 ----
CREATE TABLE booking (
    booking_id        INT AUTO_INCREMENT PRIMARY KEY,
    customer_id       INT           NOT NULL,
    type_id           INT           NOT NULL,
    booking_time      DATETIME      DEFAULT CURRENT_TIMESTAMP,
    expected_checkin  DATETIME      NOT NULL,
    expected_checkout DATETIME      NOT NULL,
    room_count        INT           NOT NULL DEFAULT 1,
    status            ENUM('已预订','已入住','已取消') NOT NULL DEFAULT '已预订',
    operator_id       INT           NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (type_id)     REFERENCES room_type(type_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='预订信息表';

-- ---- 7. 入住登记表 ----
CREATE TABLE check_in (
    checkin_id        INT AUTO_INCREMENT PRIMARY KEY,
    booking_id        INT           DEFAULT NULL,
    customer_id       INT           NOT NULL,
    room_id           VARCHAR(10)   NOT NULL,
    checkin_time      DATETIME      DEFAULT CURRENT_TIMESTAMP,
    expected_checkout DATETIME      NOT NULL,
    operator_id       INT           NOT NULL,
    status            ENUM('入住中','已退房') NOT NULL DEFAULT '入住中',
    FOREIGN KEY (booking_id)  REFERENCES booking(booking_id),
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (room_id)     REFERENCES room(room_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='入住登记表';

-- ---- 8. 换房记录表 ----
CREATE TABLE room_change (
    change_id   INT AUTO_INCREMENT PRIMARY KEY,
    checkin_id  INT          NOT NULL,
    old_room_id VARCHAR(10)  NOT NULL,
    new_room_id VARCHAR(10)  NOT NULL,
    change_time DATETIME     DEFAULT CURRENT_TIMESTAMP,
    reason      VARCHAR(255) DEFAULT NULL,
    operator_id INT          NOT NULL,
    FOREIGN KEY (checkin_id)  REFERENCES check_in(checkin_id),
    FOREIGN KEY (old_room_id) REFERENCES room(room_id),
    FOREIGN KEY (new_room_id) REFERENCES room(room_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='换房记录表';

-- ---- 9. 消费明细表 ----
CREATE TABLE consumption (
    consumption_id INT AUTO_INCREMENT PRIMARY KEY,
    checkin_id     INT           NOT NULL,
    item_name      VARCHAR(50)   NOT NULL,
    amount         DECIMAL(10,2) NOT NULL,
    create_time    DATETIME      DEFAULT CURRENT_TIMESTAMP,
    remark         VARCHAR(255)  DEFAULT NULL,
    operator_id    INT           NOT NULL,
    FOREIGN KEY (checkin_id)  REFERENCES check_in(checkin_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='消费明细表';

-- ---- 10. 退房记录表 ----
CREATE TABLE check_out (
    checkout_id    INT AUTO_INCREMENT PRIMARY KEY,
    checkin_id     INT           NOT NULL,
    checkout_time  DATETIME      DEFAULT CURRENT_TIMESTAMP,
    damage_fee     DECIMAL(10,2) DEFAULT 0.00 COMMENT '损坏赔偿',
    deposit_deduct DECIMAL(10,2) DEFAULT 0.00 COMMENT '押金抵扣金额',
    extra_pay      DECIMAL(10,2) DEFAULT 0.00 COMMENT '赔偿超出押金时补交金额',
    operator_id    INT           NOT NULL,
    FOREIGN KEY (checkin_id)  REFERENCES check_in(checkin_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='退房记录表';

-- ---- 11. 维修清洁记录表 ----
CREATE TABLE room_service (
    service_id   INT AUTO_INCREMENT PRIMARY KEY,
    room_id      VARCHAR(10)  NOT NULL,
    service_type ENUM('维修','清洁') NOT NULL,
    service_time DATETIME     DEFAULT CURRENT_TIMESTAMP,
    description  VARCHAR(255) DEFAULT NULL,
    operator_id  INT          NOT NULL,
    FOREIGN KEY (room_id)     REFERENCES room(room_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='维修清洁记录表';

-- ---- 12. 游泳池服务表 ----
CREATE TABLE pool_service (
    pool_id       INT AUTO_INCREMENT PRIMARY KEY,
    checkin_id    INT           NOT NULL,
    customer_id   INT           NOT NULL,
    use_num       INT           NOT NULL DEFAULT 1,
    cost          DECIMAL(10,2) DEFAULT 0.00,
    register_time DATETIME      DEFAULT CURRENT_TIMESTAMP,
    operator_id   INT           NOT NULL,
    FOREIGN KEY (checkin_id)  REFERENCES check_in(checkin_id),
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='游泳池服务表';

-- ---- 13. 健身房服务表 ----
CREATE TABLE gym_service (
    gym_id        INT AUTO_INCREMENT PRIMARY KEY,
    checkin_id    INT           NOT NULL,
    customer_id   INT           NOT NULL,
    use_num       INT           NOT NULL DEFAULT 1,
    cost          DECIMAL(10,2) DEFAULT 0.00,
    register_time DATETIME      DEFAULT CURRENT_TIMESTAMP,
    operator_id   INT           NOT NULL,
    FOREIGN KEY (checkin_id)  REFERENCES check_in(checkin_id),
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='健身房服务表';

-- ---- 14. 餐厅服务表 ----
CREATE TABLE dining_service (
    dining_id    INT AUTO_INCREMENT PRIMARY KEY,
    checkin_id   INT           NOT NULL,
    customer_id  INT           NOT NULL,
    diner_num    INT           NOT NULL DEFAULT 1,
    total_cost   DECIMAL(10,2) DEFAULT 0.00,
    consume_time DATETIME      DEFAULT CURRENT_TIMESTAMP,
    operator_id  INT           NOT NULL,
    FOREIGN KEY (checkin_id)  REFERENCES check_in(checkin_id),
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='餐厅服务表';

-- ---- 15. 积分流水表 ----
CREATE TABLE points_record (
    record_id     INT AUTO_INCREMENT PRIMARY KEY,
    customer_id   INT          NOT NULL,
    change_type   ENUM('获得','使用') NOT NULL COMMENT '变动类型',
    points_change INT          NOT NULL COMMENT '积分变动（获得为正，使用为负）',
    source_type   VARCHAR(30)  NOT NULL COMMENT '来源：入住结算/泳池消费/健身房消费/餐厅消费/房型升级/积分抵扣',
    source_id     INT          DEFAULT NULL COMMENT '关联业务ID',
    amount        DECIMAL(10,2) DEFAULT NULL COMMENT '关联业务实付金额或抵扣金额',
    balance_after INT          NOT NULL COMMENT '变动后积分余额',
    create_time   DATETIME     DEFAULT CURRENT_TIMESTAMP,
    remark        VARCHAR(255) DEFAULT NULL,
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id)
) ENGINE=InnoDB COMMENT='积分流水表';

-- ---- 16. 房型升级记录表 ----
CREATE TABLE room_upgrade (
    upgrade_id   INT AUTO_INCREMENT PRIMARY KEY,
    checkin_id   INT           NOT NULL,
    customer_id  INT           NOT NULL,
    old_room_id  VARCHAR(10)   NOT NULL,
    new_room_id  VARCHAR(10)   NOT NULL,
    old_price    DECIMAL(10,2) NOT NULL COMMENT '原房价格',
    new_price    DECIMAL(10,2) NOT NULL COMMENT '新房价格',
    remain_days  INT           NOT NULL COMMENT '剩余入住天数',
    points_used  INT           DEFAULT 0 COMMENT '使用积分',
    paid_amount  DECIMAL(10,2) NOT NULL COMMENT '实际支付金额',
    upgrade_time DATETIME      DEFAULT CURRENT_TIMESTAMP,
    operator_id  INT           NOT NULL,
    FOREIGN KEY (checkin_id)  REFERENCES check_in(checkin_id),
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (old_room_id) REFERENCES room(room_id),
    FOREIGN KEY (new_room_id) REFERENCES room(room_id),
    FOREIGN KEY (operator_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='房型升级记录表';


-- ============================================================
-- 第二部分：索引设计
-- ============================================================
-- room
CREATE INDEX idx_room_type_id       ON room(type_id);
CREATE INDEX idx_room_status        ON room(status);
CREATE INDEX idx_room_type_status   ON room(type_id, status);
-- ============================================================
-- 第二部分：索引设计（共30个）
-- 设计原则：
--   1. 所有外键列建立索引，加速 JOIN 操作
--   2. 高频 WHERE 筛选列建立索引（状态、时间、客户）
--   3. 复合索引用于最常见的组合查询场景
--   4. 索引并非越多越好——写操作（INSERT/UPDATE/DELETE）会同步维护索引，
--      因此只在查询频率 >> 写入频率的列上建索引
-- ============================================================

-- ---- customer 表索引 ----
-- 用途：前台办理入住时按姓名/手机号/证件号快速定位客户
CREATE INDEX idx_customer_name      ON customer(name);
CREATE INDEX idx_customer_phone     ON customer(phone);
CREATE INDEX idx_customer_idcard    ON customer(id_card);

-- ---- staff 表索引 ----
-- 用途：按岗位筛选员工，如查询所有在职前台
CREATE INDEX idx_staff_post          ON staff(post);

-- ---- booking 表索引 ----
-- 用途①：按客户查询其历史预订记录
CREATE INDEX idx_booking_customer    ON booking(customer_id);
-- 用途②：前台筛选"已预订"状态的订单用于办理入住
CREATE INDEX idx_booking_status      ON booking(status);
-- 用途③：查询今日预计到店的预订（配合 v_today_arrivals 视图）
CREATE INDEX idx_booking_exp_checkin ON booking(expected_checkin);
-- 用途④：按状态+时间排序，前台查看预订列表最常见的查询模式
CREATE INDEX idx_booking_st_time     ON booking(status, booking_time);

-- ---- check_in 表索引 ----
-- 用途①：退房/换房/消费时按客户查入住记录
CREATE INDEX idx_checkin_customer     ON check_in(customer_id);
-- 用途②：按房间号查找当前入住信息（换房、退房操作）
CREATE INDEX idx_checkin_room         ON check_in(room_id);
-- 用途③：统计前台操作员经办的入住数量
CREATE INDEX idx_checkin_operator     ON check_in(operator_id);
-- 用途④：筛选"入住中"状态的记录（在住客人列表）
CREATE INDEX idx_checkin_status       ON check_in(status);
-- 用途⑤：按入住时间排序查看近期入住
CREATE INDEX idx_checkin_time         ON check_in(checkin_time);
-- 用途⑥：查询今日预计退房的客人（配合 v_today_departures 视图）
CREATE INDEX idx_checkin_exp_checkout ON check_in(expected_checkout);

-- ---- room_change 表索引 ----
-- 用途①：查询某次入住的所有换房历史
CREATE INDEX idx_change_checkin      ON room_change(checkin_id);
-- 用途②③：换房操作时校验新旧房间是否可用
CREATE INDEX idx_change_old_room     ON room_change(old_room_id);
CREATE INDEX idx_change_new_room     ON room_change(new_room_id);

-- ---- consumption 表索引 ----
-- 用途：退房时汇总该入住的全部消费明细（最重要的账单查询）
CREATE INDEX idx_consump_checkin     ON consumption(checkin_id);

-- ---- check_out 表索引 ----
-- 用途①：按入住编号关联退房记录
CREATE INDEX idx_checkout_checkin    ON check_out(checkin_id);
-- 用途②：营收统计按日期范围筛选（v_revenue_daily 视图核心索引）
CREATE INDEX idx_checkout_time       ON check_out(checkout_time);
-- 用途③：统计前台操作员经办的退房数量
CREATE INDEX idx_checkout_operator   ON check_out(operator_id);

-- ---- room_service 表索引 ----
-- 用途：按房间号查看维修/清洁历史
CREATE INDEX idx_svc_room            ON room_service(room_id);

-- ---- 增值服务表索引 ----
-- 用途：按入住编号关联消费记录；按时间排序查看近期服务
CREATE INDEX idx_pool_checkin        ON pool_service(checkin_id);
CREATE INDEX idx_pool_time           ON pool_service(register_time);
CREATE INDEX idx_gym_checkin         ON gym_service(checkin_id);
CREATE INDEX idx_gym_time            ON gym_service(register_time);
CREATE INDEX idx_dining_checkin      ON dining_service(checkin_id);
CREATE INDEX idx_dining_time         ON dining_service(consume_time);

-- ---- points_record 表索引 ----
-- 用途①：客户查看自己的积分流水（按客户号查）
CREATE INDEX idx_points_customer      ON points_record(customer_id);
-- 用途②：按时间倒序查看最近积分变动
CREATE INDEX idx_points_time          ON points_record(create_time);

-- ---- room_upgrade 表索引 ----
-- 用途①：按入住编号查该次入住的升级记录
CREATE INDEX idx_upgrade_checkin      ON room_upgrade(checkin_id);
-- 用途②：按客户查其所有历史升级记录
CREATE INDEX idx_upgrade_customer     ON room_upgrade(customer_id);


-- ============================================================
-- 第三部分：视图设计（共8个）
-- 视图的作用：将常用查询封装为虚拟表，简化应用层 SQL、
--   统一查询口径、隔离底层表结构变化。
-- 使用场景标注：[前端页面 | 标签页] 说明该视图被哪个界面调用
-- 视图1：空闲房间列表
-- 视图2：当前在住客人信息
-- 视图3：今日预计到店预订
-- 视图4：今日预计退房
-- 视图5：房间状态汇总
-- 视图6：营收日报
-- 视图7：客户完整住宿历史
-- 视图8：增值服务营收汇总

-- ============================================================

-- 视图1：空闲房间列表
-- 场景：[customer.html"预订房间" | front_desk.html"办理入住"]
-- 用途：客户预订和前台入住时，只展示可用的空闲房间
CREATE VIEW v_available_rooms AS
SELECT r.room_id, rt.type_name, r.area, r.price, r.status
FROM room r
JOIN room_type rt ON r.type_id = rt.type_id
WHERE r.status = '空闲';

-- 视图2：当前在住客人信息
-- 场景：[front_desk.html"在住客人"]
-- 用途：前台查看所有当前在住客人，包含客户信息、房间信息和预计离店时间
CREATE VIEW v_current_guests AS
SELECT ci.checkin_id, cu.name AS customer_name, cu.phone, cu.id_card,
       r.room_id, rt.type_name, r.price,
       ci.checkin_time, ci.expected_checkout,
       su.username AS operator_name
FROM check_in ci
JOIN customer cu ON ci.customer_id = cu.customer_id
JOIN room r ON ci.room_id = r.room_id
JOIN room_type rt ON r.type_id = rt.type_id
LEFT JOIN sys_user su ON ci.operator_id = su.user_id
WHERE ci.status = '入住中';

-- 视图3：今日预计到店预订
-- 场景：[front_desk.html 概览统计 "今日将到"]
-- 用途：前台首页仪表盘展示今日预计到达的预订数量
CREATE VIEW v_today_arrivals AS
SELECT b.booking_id, cu.name, cu.phone, rt.type_name,
       b.room_count, b.expected_checkin, b.expected_checkout, b.status
FROM booking b
JOIN customer cu ON b.customer_id = cu.customer_id
JOIN room_type rt ON b.type_id = rt.type_id
WHERE DATE(b.expected_checkin) = CURDATE()
  AND b.status = '已预订';

-- 视图4：今日预计退房
-- 场景：[front_desk.html 概览统计 "今日将退"]
-- 用途：前台首页仪表盘展示今日预计退房的客人，便于提前安排清洁
CREATE VIEW v_today_departures AS
SELECT ci.checkin_id, cu.name, r.room_id, rt.type_name,
       ci.checkin_time, ci.expected_checkout
FROM check_in ci
JOIN customer cu ON ci.customer_id = cu.customer_id
JOIN room r ON ci.room_id = r.room_id
JOIN room_type rt ON r.type_id = rt.type_id
WHERE DATE(ci.expected_checkout) = CURDATE()
  AND ci.status = '入住中';

-- 视图5：房间状态汇总
-- 场景：[front_desk.html 概览统计 | manager.html]
-- 用途：按房型统计空闲/已预订/已入住/清洁中/维修中数量，用于运营概览
CREATE VIEW v_room_summary AS
SELECT rt.type_name,
       COUNT(r.room_id) AS total,
       SUM(CASE WHEN r.status = '空闲'    THEN 1 ELSE 0 END) AS vacant,
       SUM(CASE WHEN r.status = '已预订'  THEN 1 ELSE 0 END) AS booked,
       SUM(CASE WHEN r.status = '已入住'  THEN 1 ELSE 0 END) AS occupied,
       SUM(CASE WHEN r.status = '清洁中'  THEN 1 ELSE 0 END) AS cleaning,
       SUM(CASE WHEN r.status = '维修中'  THEN 1 ELSE 0 END) AS maintenance
FROM room r
JOIN room_type rt ON r.type_id = rt.type_id
GROUP BY rt.type_id, rt.type_name;

-- 视图6：营收日报（分步聚合，避免 JOIN 导致 damage_fee 重复计算）
-- 场景：[manager.html 营收统计 | admin.html 营收总览]
CREATE VIEW v_revenue_daily AS
SELECT
    dates.report_date,
    dates.checkout_count,
    COALESCE(rev.total_revenue, 0) AS total_revenue,
    COALESCE(dmg.total_damage, 0)  AS total_damage,
    COALESCE(dmg.total_extra, 0)   AS total_extra
FROM (
    SELECT DATE(checkout_time) AS report_date, COUNT(*) AS checkout_count
    FROM check_out
    WHERE checkout_time >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
    GROUP BY DATE(checkout_time)
) dates
LEFT JOIN (
    SELECT DATE(co.checkout_time) AS report_date,
           SUM(c.amount) AS total_revenue
    FROM check_out co
    JOIN consumption c ON co.checkin_id = c.checkin_id
    WHERE c.item_name NOT IN ('入住押金', '积分抵扣')
      AND co.checkout_time >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
    GROUP BY DATE(co.checkout_time)
) rev ON dates.report_date = rev.report_date
LEFT JOIN (
    SELECT DATE(checkout_time) AS report_date,
           SUM(damage_fee) AS total_damage,
           SUM(extra_pay)  AS total_extra
    FROM check_out
    WHERE checkout_time >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
    GROUP BY DATE(checkout_time)
) dmg ON dates.report_date = dmg.report_date
ORDER BY dates.report_date DESC;

-- 视图7：客户完整住宿历史
-- 场景：[customer.html"我的预订" | front_desk.html 客户查询]
-- 用途：查看客户从入住到退房的完整历史记录，包含房间和房型信息
CREATE VIEW v_customer_history AS
SELECT cu.customer_id, cu.name, cu.phone,
       ci.checkin_id, r.room_id, rt.type_name,
       ci.checkin_time, ci.expected_checkout, ci.status AS checkin_status,
       co.checkout_time
FROM customer cu
LEFT JOIN check_in ci ON cu.customer_id = ci.customer_id
LEFT JOIN room r ON ci.room_id = r.room_id
LEFT JOIN room_type rt ON r.type_id = rt.type_id
LEFT JOIN check_out co ON ci.checkin_id = co.checkin_id
ORDER BY ci.checkin_time DESC;

-- 视图8：增值服务营收汇总
-- 场景：[manager.html]
-- 用途：按服务类型（泳池/健身房/餐厅）汇总使用次数和总收入
CREATE VIEW v_service_revenue AS
SELECT '游泳池' AS service_type, COUNT(*) AS cnt, SUM(cost) AS total FROM pool_service
UNION ALL
SELECT '健身房', COUNT(*), SUM(cost) FROM gym_service
UNION ALL
SELECT '餐厅',   COUNT(*), SUM(total_cost) FROM dining_service;


-- ============================================================
-- 第四部分：安全权限设计（创建角色并授权）
-- ============================================================

-- 删除已有角色（如果存在）
DROP ROLE IF EXISTS role_admin, role_manager, role_front;
DROP USER IF EXISTS 'hotel_admin'@'localhost', 'hotel_manager'@'localhost', 'hotel_front'@'localhost';

-- 创建角色
CREATE ROLE role_admin;
CREATE ROLE role_manager;
CREATE ROLE role_front;

-- ======== role_admin：管理员，拥有全部权限 ========
GRANT ALL PRIVILEGES ON hotel_management.* TO role_admin;

-- ======== role_manager：经理 ========
-- 所有表的 SELECT 权限（可查看全部数据）
GRANT SELECT ON hotel_management.* TO role_manager;
-- 客房管理：可修改 room 和 room_type
GRANT INSERT, UPDATE, DELETE ON hotel_management.room TO role_manager;
GRANT INSERT, UPDATE, DELETE ON hotel_management.room_type TO role_manager;
-- 员工管理
GRANT INSERT, UPDATE ON hotel_management.staff TO role_manager;
-- 维修清洁
GRANT INSERT, UPDATE ON hotel_management.room_service TO role_manager;
-- 不可修改预订/入住/退房/消费等核心业务数据（只读）

-- ======== role_front：前台 ========
-- 查询权限（有限范围）
GRANT SELECT ON hotel_management.room TO role_front;
GRANT SELECT ON hotel_management.room_type TO role_front;
GRANT SELECT ON hotel_management.customer TO role_front;
-- 业务操作权限
GRANT INSERT, UPDATE ON hotel_management.booking TO role_front;
GRANT INSERT, UPDATE ON hotel_management.check_in TO role_front;
GRANT INSERT ON hotel_management.room_change TO role_front;
GRANT INSERT ON hotel_management.consumption TO role_front;
GRANT INSERT, UPDATE ON hotel_management.check_out TO role_front;
-- 前台可更新客户积分和会员等级
GRANT INSERT, UPDATE ON hotel_management.customer TO role_front;
-- 增值服务
GRANT INSERT ON hotel_management.pool_service TO role_front;
GRANT INSERT ON hotel_management.gym_service TO role_front;
GRANT INSERT ON hotel_management.dining_service TO role_front;
-- 积分和房型升级
GRANT INSERT ON hotel_management.points_record TO role_front;
GRANT INSERT ON hotel_management.room_upgrade TO role_front;
-- 前台不可修改房价、不可删除数据、不可管理用户
-- 前台不可查看员工表和系统用户表

-- 创建数据库用户并授予角色
CREATE USER 'hotel_admin'@'localhost'   IDENTIFIED BY 'admin123';
CREATE USER 'hotel_manager'@'localhost' IDENTIFIED BY 'manager123';
CREATE USER 'hotel_front'@'localhost'   IDENTIFIED BY 'front123';

GRANT role_admin   TO 'hotel_admin'@'localhost';
GRANT role_manager TO 'hotel_manager'@'localhost';
GRANT role_front   TO 'hotel_front'@'localhost';

SET DEFAULT ROLE role_admin   TO 'hotel_admin'@'localhost';
SET DEFAULT ROLE role_manager TO 'hotel_manager'@'localhost';
SET DEFAULT ROLE role_front   TO 'hotel_front'@'localhost';

FLUSH PRIVILEGES;


-- ============================================================
-- 第五部分：测试数据
-- ============================================================

-- ---- 5.1 系统用户 ----
INSERT INTO sys_user (username, password, role) VALUES
('admin',   SHA2('admin123', 256),   'admin'),
('manager', SHA2('manager123', 256), 'manager'),
('front1',  SHA2('front123', 256),   'front'),
('front2',  SHA2('front123', 256),   'front');

-- ---- 5.2 员工 ----
INSERT INTO staff (name, gender, phone, post, entry_time, user_id) VALUES
('张管理', '男', '13800001001', '管理员', '2024-01-01', 1),
('李经理', '女', '13800001002', '经理',   '2024-03-01', 2),
('王前台', '女', '13800001003', '前台',   '2024-06-01', 3),
('赵前台', '男', '13800001004', '前台',   '2025-01-01', 4),
('孙保洁', '女', '13800001005', '保洁',   '2024-09-01', NULL),
('周维修', '男', '13800001006', '维修',   '2024-09-01', NULL);

-- ---- 5.3 房型 ----
INSERT INTO room_type (type_name, default_price, total_room, surplus_room, description) VALUES
('单人间',  200.00, 10,  9, '经济实惠，适合单人入住'),
('标准间',  350.00, 20, 19, '双床房，适合两人入住'),
('大床房',  400.00, 15, 15, '一张大床，舒适宽敞'),
('套房',    688.00, 5,   5, '豪华套房，带客厅');

-- ---- 5.4 客房 ----
INSERT INTO room (room_id, type_id, area, price, status) VALUES
-- 单人间 (type_id=1)
('101', 1, 20.0, 200.00, '空闲'), ('102', 1, 20.0, 200.00, '空闲'),
('103', 1, 20.0, 200.00, '空闲'), ('104', 1, 20.0, 200.00, '已预订'),
('105', 1, 20.0, 200.00, '空闲'), ('106', 1, 20.0, 200.00, '清洁中'),
('107', 1, 20.0, 200.00, '空闲'), ('108', 1, 20.0, 200.00, '空闲'),
('109', 1, 20.0, 200.00, '维修中'), ('110', 1, 20.0, 200.00, '空闲'),
-- 标准间 (type_id=2)
('201', 2, 30.0, 350.00, '空闲'), ('202', 2, 30.0, 350.00, '清洁中'),
('203', 2, 30.0, 350.00, '空闲'), ('204', 2, 30.0, 350.00, '已预订'),
('205', 2, 30.0, 350.00, '空闲'), ('206', 2, 30.0, 350.00, '空闲'),
('207', 2, 30.0, 350.00, '空闲'), ('208', 2, 30.0, 350.00, '清洁中'),
('209', 2, 30.0, 350.00, '空闲'), ('210', 2, 30.0, 350.00, '空闲'),
('211', 2, 30.0, 350.00, '空闲'), ('212', 2, 30.0, 350.00, '空闲'),
('213', 2, 30.0, 350.00, '空闲'), ('214', 2, 30.0, 350.00, '空闲'),
('215', 2, 30.0, 350.00, '空闲'), ('216', 2, 30.0, 350.00, '空闲'),
('217', 2, 30.0, 350.00, '空闲'), ('218', 2, 30.0, 350.00, '空闲'),
('219', 2, 30.0, 350.00, '空闲'), ('220', 2, 30.0, 350.00, '空闲'),
-- 大床房 (type_id=3)
('301', 3, 35.0, 400.00, '空闲'), ('302', 3, 35.0, 400.00, '已入住'),
('303', 3, 35.0, 400.00, '空闲'), ('304', 3, 35.0, 400.00, '清洁中'),
('305', 3, 35.0, 400.00, '空闲'), ('306', 3, 35.0, 400.00, '空闲'),
('307', 3, 35.0, 400.00, '空闲'), ('308', 3, 35.0, 400.00, '空闲'),
('309', 3, 35.0, 400.00, '空闲'), ('310', 3, 35.0, 400.00, '清洁中'),
('311', 3, 35.0, 400.00, '空闲'), ('312', 3, 35.0, 400.00, '空闲'),
('313', 3, 35.0, 400.00, '空闲'), ('314', 3, 35.0, 400.00, '空闲'),
('315', 3, 35.0, 400.00, '空闲'),
-- 套房 (type_id=4)
('401', 4, 60.0, 688.00, '空闲'), ('402', 4, 60.0, 688.00, '空闲'),
('403', 4, 60.0, 688.00, '空闲'), ('404', 4, 60.0, 688.00, '已入住'),
('405', 4, 60.0, 688.00, '空闲');

-- ---- 5.5 客户 ----
INSERT INTO customer (name, gender, phone, id_card, password, member_level, points) VALUES
('刘先生', '男', '13900002001', '110101199001011234', SHA2('123456', 256), '普通',    0),
('陈女士', '女', '13900002002', '110101199205052345', SHA2('123456', 256), '普通',    0),
('黄先生', '男', '13900002003', '110101198803033456', SHA2('123456', 256), '普通', 1498),
('吴女士', '女', '13900002004', '110101199508084567', SHA2('123456', 256), '普通',  800),
('郑先生', '男', '13900002005', '110101199109095678', SHA2('123456', 256), '会员', 5681),
('林女士', '女', '13900002006', '110101199310106789', SHA2('123456', 256), '普通',    0),
('何先生', '男', '13900002007', '110101198507078901', SHA2('123456', 256), '普通',    0),
('马女士', '女', '13900002008', '110101199712120123', SHA2('123456', 256), '普通', 2088);

-- ---- 5.6 预订 ----
-- #1 郑先生预订套房(6/5→6/10，已入住) #2 吴女士预订大床房(6/6→6/8，已入住)
-- #3 刘先生预订单人间(6/12→6/15，已预订) #4 陈女士预订标准间(6/9→6/12，已预订)
-- #5 黄先生预订标准间(6/1→6/5，已入住)   #6 林女士预订单人间(已取消)
INSERT INTO booking (booking_id, customer_id, type_id, booking_time, expected_checkin, expected_checkout, room_count, status, operator_id) VALUES
(1, 5, 4, '2026-06-04 11:00:00', '2026-06-05', '2026-06-10', 1, '已入住', 3),
(2, 4, 3, '2026-06-05 09:00:00', '2026-06-06', '2026-06-08', 1, '已入住', 4),
(3, 1, 1, '2026-06-05 10:00:00', '2026-06-12', '2026-06-15', 1, '已预订', 4),
(4, 2, 2, '2026-06-03 14:30:00', '2026-06-09', '2026-06-12', 1, '已预订', 3),
(5, 3, 2, '2026-05-31 09:00:00', '2026-06-01', '2026-06-05', 1, '已入住', 4),
(6, 6, 1, '2026-05-25 08:00:00', '2026-05-28', '2026-05-30', 1, '已取消', 4);

-- ---- 5.7 入住登记 ----
-- #1 郑先生(会员) 套房404，5天，6/5→6/10（在住，总消费3096达到会员续保标准）
-- #2 吴女士(普通) 大床房302，2天，6/6→6/8（在住，今日预计退房）
-- #3 黄先生(普通) 标准间202，4天，6/1→6/5（已退房）
-- #4 马女士(普通) 大床房304，4天，6/2→6/6（已退房）
INSERT INTO check_in (checkin_id, booking_id, customer_id, room_id, checkin_time, expected_checkout, operator_id, status) VALUES
(1, 1, 5, '404', '2026-06-05 15:00:00', '2026-06-10 12:00:00', 3, '入住中'),
(2, 2, 4, '302', '2026-06-06 12:00:00', '2026-06-08 12:00:00', 4, '入住中'),
(3, 5, 3, '202', '2026-06-01 14:00:00', '2026-06-05 12:00:00', 4, '已退房'),
(4, NULL, 8, '304', '2026-06-02 16:00:00', '2026-06-06 12:00:00', 3, '已退房');

-- ---- 5.8 消费明细 ----
-- 房费 = 房价 x 天数（会员9折，积分抵扣另算），押金不计入总消费
-- checkin #1 郑先生(会员): 套房 688x5天=3440，会员9折=3096.00（总消费达标3000）
-- checkin #2 吴女士(普通): 大床房 400x2天=800
-- checkin #3 黄先生(普通): 标准间 350x4天=1400，积分抵扣200=2元，实付1398
-- checkin #4 马女士(普通): 大床房 400x4天=1600
INSERT INTO consumption (checkin_id, item_name, amount, operator_id, remark) VALUES
(1, '房费',     3096.00, 3, '5天 688元 会员9折'),
(1, '入住押金', 1000.00, 3, '信用卡'),
(2, '房费',      800.00, 4, '2天 400元'),
(2, '入住押金',  500.00, 4, '现金'),
(3, '房费',     1398.00, 4, '4天 350元'),
(3, '积分抵扣',    2.00, 4, '使用200积分'),
(3, '入住押金',  500.00, 4, '现金'),
(4, '房费',     1600.00, 3, '4天 400元'),
(4, '入住押金',  500.00, 3, '微信支付');

-- ---- 5.9 退房记录 ----
-- #3 黄先生退房(6/5)：无损坏，押金全退
-- #4 马女士退房(6/6)：损坏赔偿150元，从押金抵扣
INSERT INTO check_out (checkin_id, checkout_time, damage_fee, deposit_deduct, extra_pay, operator_id) VALUES
(3, '2026-06-05 12:00:00',   0.00,   0.00, 0.00, 4),
(4, '2026-06-06 10:00:00', 150.00, 150.00, 0.00, 3);

-- ---- 5.10 换房记录 ----
-- 郑先生(5)入住期间从404换到403（6/6空调故障）
INSERT INTO room_change (checkin_id, old_room_id, new_room_id, reason, operator_id) VALUES
(1, '404', '403', '空调故障，换至同楼层', 3);
-- 注意：check_in 表中 room_id 已手动改为 403（见上方 UPDATE 注释）
-- 由于换房发生在 6/6，在测试数据中 6/6 以后郑先生住在 403

-- ---- 5.11 维修清洁记录 ----
INSERT INTO room_service (room_id, service_type, description, operator_id) VALUES
('106', '清洁', '退房后清洁', 3),
('109', '维修', '马桶堵塞维修', 2),
('202', '清洁', '黄先生退房后清洁', 4),
('208', '清洁', '退房后清洁', 4),
('304', '清洁', '马女士退房后清洁', 3),
('310', '清洁', '退房后清洁', 3);

-- ---- 5.12 增值服务（泳池/健身房/餐厅） ----
-- 郑先生(5,会员) 泳池2次100元、餐厅2人258元
-- 黄先生(3,普通) 泳池1次100元、健身房1次0元（免费）
-- 马女士(8,普通) 泳池1次100元、餐厅1人88元
INSERT INTO pool_service (checkin_id, customer_id, use_num, cost, operator_id) VALUES
(1, 5, 2, 100.00, 3),
(3, 3, 1, 100.00, 4),
(4, 8, 1, 100.00, 3);

INSERT INTO gym_service (checkin_id, customer_id, use_num, cost, operator_id) VALUES
(3, 3, 1, 0.00, 4);

INSERT INTO dining_service (checkin_id, customer_id, diner_num, total_cost, operator_id) VALUES
(1, 5, 2, 258.00, 3),
(4, 8, 1,  88.00, 3);

-- ---- 5.13 积分流水（来源：入住结算 / 泳池消费 / 健身房消费 / 餐厅消费 / 积分抵扣） ----
INSERT INTO points_record (customer_id, change_type, points_change, source_type, source_id, amount, balance_after, remark) VALUES
-- 郑先生(5,会员,初始500) 入住结算: 3096.00x1.5=4644 → 积5144
(5, '获得', 4644, '入住结算', 1, 3096.00, 5144, '会员1.5倍积分'),
-- 郑先生(5) 泳池消费: 100x1.5=150 → 积5294
(5, '获得',  150, '泳池消费', 1,  100.00, 5294, '会员1.5倍积分'),
-- 郑先生(5) 餐厅消费: 258x1.5=387 → 积5681
(5, '获得',  387, '餐厅消费', 1,  258.00, 5681, '会员1.5倍积分'),
-- 吴女士(4,普通,初始0) 入住结算: 800×1=800 → 积800
(4, '获得',  800, '入住结算', 2,  800.00,  800, '普通用户1倍积分'),
-- 黄先生(3,普通,初始200) 入住结算: 1398×1=1398 → 积1598
(3, '获得', 1398, '入住结算', 3, 1398.00, 1598, '普通用户1倍积分'),
-- 黄先生(3) 使用200积分抵扣: -200 → 积1398
(3, '使用', -200, '积分抵扣', 3,    2.00, 1398, '使用200积分抵扣2元'),
-- 黄先生(3) 泳池消费: 100×1=100 → 积1498
(3, '获得',  100, '泳池消费', 3,  100.00, 1498, '普通用户1倍积分'),
-- 马女士(8,普通,初始300) 入住结算: 1600×1=1600 → 积1900
(8, '获得', 1600, '入住结算', 4, 1600.00, 1900, '普通用户1倍积分'),
-- 马女士(8) 泳池消费: 100×1=100 → 积2000
(8, '获得',  100, '泳池消费', 4,  100.00, 2000, '普通用户1倍积分'),
-- 马女士(8) 餐厅消费: 88×1=88 → 积2088
(8, '获得',   88, '餐厅消费', 4,   88.00, 2088, '普通用户1倍积分');

-- ---- 5.14 换房后 room 与 check_in 状态修正 ----
-- 郑先生 checkin_id=1 已于6/6从404换到403，手动更新房间和入住记录
UPDATE check_in SET room_id = '403' WHERE checkin_id = 1;
UPDATE room SET status = '空闲' WHERE room_id = '404';
UPDATE room SET status = '已入住' WHERE room_id = '403';


-- ============================================================
-- 第六部分：功能测试查询语句（25条，适配新测试数据）
-- ============================================================

-- Q1: 查询所有空闲房间及房型信息
SELECT r.room_id, rt.type_name, r.area, r.price, r.status
FROM room r JOIN room_type rt ON r.type_id = rt.type_id
WHERE r.status = '空闲'
ORDER BY rt.type_id, r.room_id;

-- Q2: 按客户姓名模糊查询
SELECT * FROM customer WHERE name LIKE '%郑%';

-- Q3: 按手机号精确查询客户
SELECT * FROM customer WHERE phone = '13900002005';

-- Q4: 查询今日预计到店的预订（使用视图，6/12 刘先生 + 6/9 陈女士 未到当天为空属正常）
SELECT * FROM v_today_arrivals;

-- Q5: 查询当前所有在住客人（应显示郑先生#1 + 吴女士#2）
SELECT * FROM v_current_guests;

-- Q6: 查询今日预计退房的房间（6/8 吴女士）
SELECT * FROM v_today_departures;

-- Q7: 各房型房间状态汇总
SELECT * FROM v_room_summary;

-- Q8: 查询郑先生(customer_id=5)的完整住宿历史
SELECT * FROM v_customer_history WHERE customer_id = 5;

-- Q9: 查询 checkin #1（郑先生）的消费明细
SELECT item_name, amount, create_time, remark
FROM consumption WHERE checkin_id = 1 ORDER BY create_time;

-- Q10: 按入住编号汇总消费总金额（区分押金与费用）
SELECT checkin_id,
       SUM(CASE WHEN item_name = '入住押金' THEN amount ELSE 0 END) AS deposit,
       SUM(CASE WHEN item_name != '入住押金' THEN amount ELSE 0 END) AS charges,
       SUM(amount) AS total
FROM consumption GROUP BY checkin_id;

-- Q11: 近7天营收统计（退房+消费明细，排除押金和积分抵扣）
SELECT DATE(co.checkout_time) AS day,
       COUNT(DISTINCT co.checkin_id) AS orders,
       COALESCE(SUM(c.amount), 0) AS revenue
FROM check_out co
JOIN consumption c ON co.checkin_id = c.checkin_id
WHERE c.item_name NOT IN ('入住押金', '积分抵扣')
  AND co.checkout_time >= DATE_SUB(CURDATE(), INTERVAL 7 DAY)
GROUP BY DATE(co.checkout_time) ORDER BY day DESC;

-- Q12: 查询维修中的房间
SELECT r.room_id, rt.type_name, r.remark
FROM room r JOIN room_type rt ON r.type_id = rt.type_id
WHERE r.status = '维修中';

-- Q13: 按前台经办人统计工作量
SELECT su.username,
       COUNT(DISTINCT ci.checkin_id) AS checkins,
       COUNT(DISTINCT co.checkout_id) AS checkouts
FROM sys_user su
LEFT JOIN check_in ci ON su.user_id = ci.operator_id
LEFT JOIN check_out co ON su.user_id = co.operator_id
WHERE su.role = 'front'
GROUP BY su.user_id, su.username;

-- Q14: 查询标准间202的入住历史
SELECT ci.checkin_id, cu.name, ci.checkin_time, ci.expected_checkout, ci.status
FROM check_in ci JOIN customer cu ON ci.customer_id = cu.customer_id
WHERE ci.room_id = '202' ORDER BY ci.checkin_time DESC;

-- Q15: 所有换房记录及对应客户
SELECT rc.change_id, cu.name AS customer_name,
       rc.old_room_id, rc.new_room_id, rc.change_time, rc.reason
FROM room_change rc
JOIN check_in ci ON rc.checkin_id = ci.checkin_id
JOIN customer cu ON ci.customer_id = cu.customer_id;

-- Q16: 增值服务营收汇总（泳池/健身房/餐厅）
SELECT * FROM v_service_revenue;

-- Q17: 各房型当前入住率
SELECT rt.type_name, rt.total_room,
       COUNT(CASE WHEN r.status = '已入住' THEN 1 END) AS occupied,
       ROUND(COUNT(CASE WHEN r.status='已入住' THEN 1 END)/rt.total_room*100, 1) AS occupancy_rate
FROM room_type rt LEFT JOIN room r ON rt.type_id = r.type_id
GROUP BY rt.type_id, rt.type_name, rt.total_room;

-- Q18: 最近30天营收日报（使用视图 v_revenue_daily）
SELECT * FROM v_revenue_daily;

-- Q19: 多条件组合查询：标准间 + 空闲 + 300~400元
SELECT r.room_id, rt.type_name, r.price, r.status
FROM room r JOIN room_type rt ON r.type_id = rt.type_id
WHERE r.type_id = 2 AND r.status = '空闲' AND r.price BETWEEN 300 AND 400;

-- Q20: 所有预订订单及客户和经办人信息
SELECT b.booking_id, cu.name AS customer_name, cu.phone,
       rt.type_name, b.room_count, b.expected_checkin,
       b.expected_checkout, b.status, su.username AS operator_name
FROM booking b
JOIN customer cu ON b.customer_id = cu.customer_id
JOIN room_type rt ON b.type_id = rt.type_id
JOIN sys_user su ON b.operator_id = su.user_id
ORDER BY b.booking_time DESC;

-- Q21: 查询所有会员客户
SELECT customer_id, name, phone, member_level, points
FROM customer WHERE member_level = '会员';

-- Q22: 查询郑先生(customer_id=5)的积分流水
SELECT pr.*, cu.name FROM points_record pr
JOIN customer cu ON pr.customer_id = cu.customer_id
WHERE pr.customer_id = 5 ORDER BY pr.create_time DESC;

-- Q23: 各客户当前积分余额排名
SELECT customer_id, name, phone, member_level, points
FROM customer ORDER BY points DESC;

-- Q24: 房型升级记录（本版测试数据无升级记录，验证空结果）
SELECT * FROM room_upgrade;

-- Q25: 客户累计消费金额统计（排除押金和积分抵扣）
SELECT ci.customer_id, cu.name,
       SUM(CASE WHEN c.item_name NOT IN ('入住押金','积分抵扣') THEN c.amount ELSE 0 END) AS total_spent
FROM consumption c
JOIN check_in ci ON c.checkin_id = ci.checkin_id
JOIN customer cu ON ci.customer_id = cu.customer_id
GROUP BY ci.customer_id, cu.name
ORDER BY total_spent DESC;
