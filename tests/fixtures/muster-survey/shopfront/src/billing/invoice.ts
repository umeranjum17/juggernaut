export interface Invoice {
  id: string;
  orderId: string;
  status: 'open' | 'settled';
}
