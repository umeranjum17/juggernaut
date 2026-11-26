export type OrderStatus = 'draft' | 'paid' | 'shipped' | 'cancelled';

export class Order {
  id: string;
  customerId: string;
  total: number;
  status: OrderStatus = 'draft';

  pay(): void {
    if (this.status !== 'draft') throw new Error('only a draft order can be paid');
    this.status = 'paid';
  }

  ship(): void {
    if (this.status !== 'paid') throw new Error('only a paid order can ship');
    this.status = 'shipped';
  }

  cancel(): void {
    if (this.status === 'shipped') throw new Error('a shipped order cannot be cancelled');
    this.status = 'cancelled';
  }
}
