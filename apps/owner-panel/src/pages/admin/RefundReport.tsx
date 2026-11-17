import { OrderStatusReportView } from './OrderStatusReport'

export default function RefundReport() {
  return (
    <OrderStatusReportView
      type="cancelled"
      pageTitle="Laporan Refund"
      totalLabel="Total Refund"
      statAccent="#F59E0B"
    />
  )
}