export enum ParcelState {
  Packed = 'packed',
  InTransit = 'in-transit',
  Delivered = 'delivered',
}

export class Parcel {
  orderId: string;
  state: ParcelState = ParcelState.Packed;

  dispatch(): void {
    this.state = ParcelState.InTransit;
  }
}
