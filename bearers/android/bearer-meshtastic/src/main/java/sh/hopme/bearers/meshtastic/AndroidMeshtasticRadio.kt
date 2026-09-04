package sh.hopme.bearers.meshtastic

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import sh.hop.TAG
import java.util.ArrayDeque
import java.util.UUID

/** Real Meshtastic GATT client. All connect/write/read calls run on the main looper. */
internal class AndroidMeshtasticRadio(private val context: Context) : MeshtasticRadio {
    override var onConnect: (() -> Unit)? = null
    override var onDisconnect: (() -> Unit)? = null
    override var onFromRadio: ((ByteArray) -> Unit)? = null

    private val serviceUuid = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    private val toRadioUuid = UUID.fromString("f75c76d2-129e-4dad-a1dd-7866124401e7")
    private val fromRadioUuid = UUID.fromString("2c55e69e-4993-11ed-b878-0242ac120002")
    private val fromNumUuid = UUID.fromString("ed9da18c-a800-4f66-a670-aa7547e34453")
    private val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private var adapter: BluetoothAdapter? = null
    private var gatt: BluetoothGatt? = null
    private var toRadio: BluetoothGattCharacteristic? = null
    private var fromRadio: BluetoothGattCharacteristic? = null
    private var running = false
    private var armed = false
    private val pendingToRadio = ArrayDeque<ByteArray>()
    private var writingToRadio = false
    private val main = Handler(Looper.getMainLooper())

    @SuppressLint("MissingPermission")
    override fun start() {
        running = true
        armed = false
        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return
        adapter = mgr.adapter
        val named: (BluetoothDevice) -> Boolean = { it.name?.startsWith("Meshtastic") == true }
        val already = mgr.getConnectedDevices(BluetoothProfile.GATT).firstOrNull(named)
        if (already != null) {
            Log.i(TAG, "mesh radio attach connected=${already.address}")
            connectDevice(already)
            return
        }
        startScan()
    }

    @SuppressLint("MissingPermission")
    override fun stop() {
        running = false
        armed = false
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        runCatching { gatt?.disconnect(); gatt?.close() }
        gatt = null; toRadio = null; fromRadio = null
        pendingToRadio.clear(); writingToRadio = false
    }

    override fun sendToRadio(bytes: ByteArray) {
        main.post {
            pendingToRadio.add(bytes)
            kickToRadio()
        }
    }

    @SuppressLint("MissingPermission")
    private fun kickToRadio() {
        if (writingToRadio) return
        val g = gatt ?: return
        val ch = toRadio ?: return
        val bytes = pendingToRadio.poll() ?: return
        writingToRadio = true
        @Suppress("DEPRECATION")
        ch.value = bytes
        val ok = g.writeCharacteristic(ch)
        Log.i(TAG, "mesh toRadio write len=${bytes.size} ok=$ok")
        if (!ok) {
            writingToRadio = false
            pendingToRadio.addFirst(bytes)
            main.postDelayed({ kickToRadio() }, 80)
        }
    }

    @SuppressLint("MissingPermission")
    private fun connectDevice(device: BluetoothDevice) {
        main.post {
            if (!running || gatt != null) return@post
            Log.i(TAG, "mesh radio connectGatt ${device.address}")
            gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        val scanner = adapter?.bluetoothLeScanner ?: run {
            Log.w(TAG, "mesh radio scan: no LE scanner"); return
        }
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceUuid)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        Log.i(TAG, "mesh radio scan")
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (gatt != null) return
            adapter?.bluetoothLeScanner?.stopScan(this)
            Log.i(TAG, "mesh radio scan hit ${result.device.address}")
            connectDevice(result.device)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            Log.i(TAG, "mesh gatt state=$newState status=$status")
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (!g.requestMtu(512)) g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    toRadio = null; fromRadio = null; gatt = null
                    writingToRadio = false; armed = false
                    runCatching { g.close() }
                    onDisconnect?.invoke()
                    if (running) {
                        Log.i(TAG, "mesh radio dropped, scanning")
                        startScan()
                    }
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            Log.i(TAG, "mesh mtu=$mtu status=$status")
            if (toRadio == null) g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (armed) return
            val svc = g.getService(serviceUuid)
            Log.i(TAG, "mesh services status=$status svc=${svc != null}")
            if (svc == null) return
            toRadio = svc.getCharacteristic(toRadioUuid)
            fromRadio = svc.getCharacteristic(fromRadioUuid)
            val fromNum = svc.getCharacteristic(fromNumUuid)
            val cccd = fromNum?.getDescriptor(cccdUuid)
            Log.i(TAG, "mesh chars to=${toRadio != null} from=${fromRadio != null} fromNum=${fromNum != null} cccd=${cccd != null}")
            toRadio?.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            if (fromNum != null) g.setCharacteristicNotification(fromNum, true)
            if (cccd != null) {
                @Suppress("DEPRECATION")
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                g.writeDescriptor(cccd)
            } else {
                arm(g)
            }
        }

        private fun arm(g: BluetoothGatt) {
            if (armed || toRadio == null || fromRadio == null) return
            armed = true
            onConnect?.invoke()
            fromRadio?.let { g.readCharacteristic(it) }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            Log.i(TAG, "mesh cccd status=$status")
            if (status == BluetoothGatt.GATT_SUCCESS) {
                arm(g)
            } else {
                main.postDelayed({ if (running) arm(g) }, 800)
            }
        }


        @SuppressLint("MissingPermission")
        override fun onCharacteristicWrite(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            Log.i(TAG, "mesh toRadio written status=$status")
            writingToRadio = false
            if (pendingToRadio.isNotEmpty()) {
                kickToRadio()
            } else if (status == BluetoothGatt.GATT_SUCCESS) {
                fromRadio?.let { g.readCharacteristic(it) }
            }
        }

        @SuppressLint("MissingPermission")
        private fun onFromNum(g: BluetoothGatt, uuid: UUID) {
            if (uuid == fromNumUuid) fromRadio?.let { g.readCharacteristic(it) }
        }

        @SuppressLint("MissingPermission")
        private fun onFromRadioValue(g: BluetoothGatt, uuid: UUID, value: ByteArray?) {
            if (uuid != fromRadioUuid) return
            Log.i(TAG, "mesh fromRadio len=${value?.size ?: -1}")
            if (value != null && value.isNotEmpty()) {
                onFromRadio?.invoke(value)
                fromRadio?.let { g.readCharacteristic(it) }
            }
        }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) =
            onFromNum(g, ch.uuid)

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) =
            onFromNum(g, ch.uuid)

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION")
            onFromRadioValue(g, ch.uuid, ch.value)
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) = onFromRadioValue(g, ch.uuid, value)
    }
}
