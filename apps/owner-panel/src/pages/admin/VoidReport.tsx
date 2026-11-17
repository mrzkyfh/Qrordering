import { OrderStatusReportView } from './OrderStatusReport'

export default function VoidReport() {
  return (
    <OrderStatusReportView
      type="void"
      pageTitle="Laporan Void"
      totalLabel="Total Void"
      statAccent="#EF4444"
    />
  )
}