"""只读查看 B 当前设施或订单，使用仓库公共 DB_* 连接配置。"""
import argparse
import json

from app.database.connection import database_connection
from app.database.charging_repository import customer_orders, order_funds, station_guns


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--order',type=int)
    group.add_argument('--user',type=int)
    group.add_argument('--station',type=int)
    args=parser.parse_args()
    with database_connection() as connection:
        if args.order is not None:
            result=order_funds(connection,order_id=args.order)
        elif args.user is not None:
            result=customer_orders(connection,user_id=args.user)
        else:
            result=station_guns(connection,station_id=args.station)
        print(json.dumps(result,ensure_ascii=False,indent=2,default=str))


if __name__=='__main__':
    main()
