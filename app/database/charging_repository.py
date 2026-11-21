"""B 查询入口，使用调用方的公共连接和参数化 SQL。"""


def order_funds(connection, *, order_id):
    with connection.cursor() as cursor:
        cursor.execute('SELECT * FROM v_b_order_funds WHERE order_id=%s',(order_id,))
        return cursor.fetchone()


def customer_orders(connection, *, user_id, after_order_id=0, limit=20):
    if type(limit) is not int or not 1<=limit<=100:
        raise ValueError('分页大小必须为 1 至 100 的整数')
    with connection.cursor() as cursor:
        cursor.execute('''SELECT * FROM v_b_order_funds
            WHERE user_id=%s AND order_id>%s ORDER BY order_id LIMIT %s''',
            (user_id,after_order_id,limit))
        return cursor.fetchall()


def station_guns(connection, *, station_id):
    with connection.cursor() as cursor:
        cursor.execute('SELECT * FROM v_b_gun_availability WHERE station_id=%s ORDER BY gun_id',(station_id,))
        return cursor.fetchall()
