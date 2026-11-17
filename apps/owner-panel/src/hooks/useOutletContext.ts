import { useContext } from 'react'
import { OutletContext } from '@/contexts/outlet-context'

export function useOutletContext() {
  const context = useContext(OutletContext)
  if (!context) {
    throw new Error('useOutletContext must be used within an OutletProvider')
  }
  return context
}
