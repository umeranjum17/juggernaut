import { describe, it, expect } from 'vitest';
import { Order } from '../src/orders/order';

describe('Order', () => {
  it('pays a draft order', () => {
    const o = new Order();
    o.pay();
    expect(o.status).toBe('paid');
  });

  it('refuses to cancel a shipped order', () => {
    const o = new Order();
    o.pay();
    o.ship();
    expect(() => o.cancel()).toThrow();
  });
});
