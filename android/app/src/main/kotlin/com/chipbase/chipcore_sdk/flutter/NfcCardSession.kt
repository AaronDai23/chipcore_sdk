package com.chipcore.sdk.flutter

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.text.InputType
import android.util.Log
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import com.google.android.material.bottomsheet.BottomSheetDialog
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

// ─── Data classes ─────────────────────────────────────────────────────────────

internal data class Iso7816Response(
    val cardId: String,
    val response: ByteArray,
)

internal data class SessionChannel(
    val tag: Tag,
    val isoDep: IsoDep,
    /** SELECT APPLET 响应的原始数据部分（已去掉末尾 SW1SW2），用于构造 AES 会话密钥 */
    val aesKey: ByteArray,
)

internal data class KeyMaterial(
    val publicKey: ByteArray,
    val chainCode: ByteArray,
)

internal data class CardStatus(
    val hasKeyPair: Boolean,
    /** 原始 hasKeyPair 标志位（不考虑密钥材料是否有效） */
    val masterKeyFlagSet: Boolean = hasKeyPair,
    val pinSet: Boolean,
    val uid: ByteArray?,
    val version: String?,
    val versionCode: String?,
    val resetCount: Long,
    /** PIN 剩余重试次数；0 表示 PIN 已被锁定 */
    val pinRetry: Int = 3,
    /** PUK 剩余重试次数；0 表示卡片已作废 */
    val pukRetry: Int = 5,
) {
    /** 卡片已锁（PIN 已耗尽，需 PUK 解锁） */
    val isLock: Boolean get() = pinRetry == 0 && pukRetry > 0
    /** 卡片已作废（PUK 也已耗尽） */
    val isExpired: Boolean get() = pinRetry == 0 && pukRetry == 0
}

internal data class MasterKey(
    val publicKey: ByteArray,
    val chainCode: ByteArray,
)

internal data class CardSnapshot(
    val cardId: String,
    val uid: String,
    val isPasswordSet: Boolean,
    val masterPublicKey: ByteArray,
    val masterChainCode: ByteArray,
    val currencies: List<Messages.CurrencyInfoMessage>,
)

// ─── AndroidIso7816SessionManager ────────────────────────────────────────────

internal class AndroidIso7816SessionManager(private val activity: Activity) {
    companion object {
        private const val NFC_LOG_TAG = "ChipCoreNfc"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var isListening = false
    private var nfcDialog: BottomSheetDialog? = null
    private var cancelAction: (() -> Unit)? = null
    private var pendingTimeout: Runnable? = null

    fun transceive(
        appletId: ByteArray?,
        command: ByteArray,
        callback: (Result<Iso7816Response>) -> Unit,
    ) {
        withSession(
            appletId,
            operation = { channel ->
                Result.success(Iso7816Response(cardId = channel.tag.id.toHex(), response = channel.isoDep.transceive(command)))
            },
            callback = callback,
        )
    }

    fun <T> withSession(
        appletId: ByteArray?,
        operation: (SessionChannel) -> Result<T>,
        callback: (Result<T>) -> Unit,
        dialogTitle: String = "Ready to scan",
        dialogMessage: String = "Hold the card against the back of your phone",
    ) {
        val adapter = NfcAdapter.getDefaultAdapter(activity)
            ?: run {
                Log.e(NFC_LOG_TAG, "NFC unavailable on device")
                callback(Result.failure(Messages.FlutterError("nfc-unavailable", "NFC is not supported on this device", null)))
                return
            }
        if (!adapter.isEnabled) {
            Log.w(NFC_LOG_TAG, "NFC is disabled")
            callback(Result.failure(Messages.FlutterError("nfc-disabled", "Please enable NFC in system settings", null)))
            return
        }

        Log.i(
            NFC_LOG_TAG,
            "withSession start, appletId=${appletId?.toHex() ?: "null"}, dialogTitle=$dialogTitle, activity=${activity::class.java.simpleName}",
        )

        val completed = AtomicBoolean(false)
        val timeoutRunnable = Runnable {
            Log.w(NFC_LOG_TAG, "NFC session timeout after 30 seconds")
            finish(adapter)
            if (completed.compareAndSet(false, true)) {
                callback(Result.failure(Messages.FlutterError("nfc-timeout", "Session timed out. Hold your card closer and try again", null)))
            }
        }

        mainHandler.post {
            cancelAction = {
                Log.i(NFC_LOG_TAG, "NFC session cancelled by user")
                mainHandler.removeCallbacks(timeoutRunnable)
                finish(adapter)
                if (completed.compareAndSet(false, true)) {
                    callback(Result.failure(Messages.FlutterError("user-cancelled", "Session invalidated by user", null)))
                }
            }
            showNfcDialog(dialogTitle, dialogMessage)

            Log.d(NFC_LOG_TAG, "enableReaderMode")
            adapter.enableReaderMode(
                activity,
                { tag ->
                    Log.i(NFC_LOG_TAG, "NFC tag discovered, id=${tag.id?.toHex() ?: "unknown"}")
                    handleTag(tag, appletId, adapter, completed, callback, operation)
                },
                NfcAdapter.FLAG_READER_NFC_A or
                    NfcAdapter.FLAG_READER_NFC_B or
                    NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
                    NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS,
                Bundle().apply {
                    putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250)
                },
            )
            isListening = true
            pendingTimeout = timeoutRunnable
            mainHandler.postDelayed(timeoutRunnable, 30_000)
        }
    }

    fun reset() {
        val adapter = NfcAdapter.getDefaultAdapter(activity) ?: return
        finish(adapter)
    }

    /**
     * 在主线程弹出原生 PIN 输入对话框。
     * 用户点击「确认」后通过 callback 返回 PIN 字节数组（每位一个 byte，值 0-9）；
     * 取消或输入非法时返回 null。
     */
    fun showPinInputDialog(
        title: String = "PIN Required",
        message: String = "Please enter the card PIN to proceed",
        callback: (ByteArray?) -> Unit,
    ) {
        mainHandler.post {
            val ctx = ContextThemeWrapper(
                activity,
                com.google.android.material.R.style.Theme_Material3_Light_NoActionBar,
            )
            val dp = activity.resources.displayMetrics.density
            val container = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                setPadding((24 * dp).toInt(), (16 * dp).toInt(), (24 * dp).toInt(), 0)
            }
            val editText = EditText(ctx).apply {
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
                hint = "Enter 6-digit PIN"
                gravity = Gravity.CENTER
            }
            container.addView(editText)

            AlertDialog.Builder(ctx)
                .setTitle(title)
                .setMessage(message)
                .setView(container)
                .setPositiveButton("Confirm") { _, _ ->
                    val pinStr = editText.text.toString()
                    if (pinStr.isEmpty()) {
                        callback(null)
                    } else {
                        val pinBytes = pinStr.map { (it - '0').toByte() }.toByteArray()
                        callback(pinBytes)
                    }
                }
                .setNegativeButton("Cancel") { _, _ -> callback(null) }
                .setCancelable(false)
                .show()
        }
    }

    private fun <T> handleTag(
        tag: Tag,
        appletId: ByteArray?,
        adapter: NfcAdapter,
        completed: AtomicBoolean,
        callback: (Result<T>) -> Unit,
        operation: (SessionChannel) -> Result<T>,
    ) {
        val isoDep = IsoDep.get(tag)
        if (isoDep == null) {
            Log.e(NFC_LOG_TAG, "Detected tag does not support ISO-DEP")
            complete(adapter, completed, callback, Result.failure(Messages.FlutterError("tag-unsupported", "Tag does not support ISO-DEP", null)))
            return
        }

        try {
            Log.d(NFC_LOG_TAG, "Connecting IsoDep")
            isoDep.connect()
            isoDep.timeout = 15_000
            var aesKeyBytes = byteArrayOf()
            if (appletId != null && appletId.isNotEmpty()) {
                Log.d(NFC_LOG_TAG, "Selecting applet ${appletId.toHex()}")
                val selectResponse = isoDep.transceive(buildSelectApdu(appletId))
                ensureSuccessStatus(selectResponse, "选择 applet 失败")
                // 去掉末尾 SW1SW2，剩余字节即为卡片返回的 AES 密钥材料
                aesKeyBytes = selectResponse.copyOf(selectResponse.size - 2)
                Log.d(NFC_LOG_TAG, "SELECT aesKeyBase [${aesKeyBytes.size}] ${aesKeyBytes.toHex()}")
            }
            Log.d(NFC_LOG_TAG, "Running NFC operation")
            complete(
                adapter,
                completed,
                callback,
                operation(SessionChannel(tag = tag, isoDep = isoDep, aesKey = aesKeyBytes)),
            )
        } catch (error: Throwable) {
            Log.e(NFC_LOG_TAG, "NFC operation failed: ${error.message}", error)
            complete(adapter, completed, callback, Result.failure(wrapThrowable(error)))
        } finally {
            try {
                isoDep.close()
            } catch (_: IOException) {
            }
        }
    }

    private fun <T> complete(
        adapter: NfcAdapter,
        completed: AtomicBoolean,
        callback: (Result<T>) -> Unit,
        result: Result<T>,
    ) {
        Log.d(NFC_LOG_TAG, "NFC session complete, success=${result.isSuccess}")
        finish(adapter, vibrate = result.isSuccess)
        if (completed.compareAndSet(false, true)) {
            mainHandler.post { callback(result) }
        }
    }

    private fun finish(adapter: NfcAdapter, vibrate: Boolean = false) {
        pendingTimeout?.let { mainHandler.removeCallbacks(it) }
        pendingTimeout = null
        if (!isListening) {
            Log.d(NFC_LOG_TAG, "finish skipped because reader mode is not active")
            return
        }
        isListening = false
        runCatching { adapter.disableReaderMode(activity) }
        Log.d(NFC_LOG_TAG, "disableReaderMode called (sync)")
        if (vibrate) {
            // 在 NFC 后台线程直接发震动 IPC，然后 sleep 100ms 等马达激活，
            // 再 post 关闭弹窗——确保弹窗关闭时震动已在播放
            vibrateSingleTap()
            try { Thread.sleep(100) } catch (_: InterruptedException) {}
        }
        mainHandler.post {
            cancelAction = null
            dismissNfcDialog()
        }
    }

    /** 单次触觉反馈，替代被 FLAG_READER_NO_PLATFORM_SOUNDS 屏蔽的系统 NFC 震动 */
    private fun vibrateSingleTap() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = activity.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vm?.defaultVibrator?.vibrate(
                    VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
                )
            } else {
                @Suppress("DEPRECATION")
                val vibrator = activity.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(VibrationEffect.createOneShot(100, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(100)
                }
            }
        } catch (_: Exception) {
            // 震动失败不影响 NFC 流程
        }
    }

    private fun showNfcDialog(title: String, message: String) {
        Log.d(NFC_LOG_TAG, "showNfcDialog called, title=$title, message=$message")
        runCatching { nfcDialog?.dismiss() }
        val dp = activity.resources.displayMetrics.density

        // 用 Material3 主题包装 context，避免导航栏主题导致 BottomSheetDialog 渲染失败
        // 所用库: com.google.android.material (Apache 2.0)
        val ctx = ContextThemeWrapper(
            activity,
            com.google.android.material.R.style.Theme_Material3_Light_NoActionBar,
        )

        val root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding((24 * dp).toInt(), (32 * dp).toInt(), (24 * dp).toInt(), (32 * dp).toInt())
        }

        // NFC 图标
        root.addView(TextView(ctx).apply {
            text = "📲"
            textSize = 48f
            gravity = Gravity.CENTER
        })

        // 标题
        root.addView(TextView(ctx).apply {
            text = title
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#1A1A1A"))
            setPadding(0, (14 * dp).toInt(), 0, (6 * dp).toInt())
        })

        // 副标题
        root.addView(TextView(ctx).apply {
            text = message
            textSize = 14f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#888888"))
            setPadding(0, 0, 0, (20 * dp).toInt())
        })

        // 旋转进度条
        root.addView(ProgressBar(ctx).apply {
            isIndeterminate = true
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).also { it.gravity = Gravity.CENTER_HORIZONTAL }
        })

        // 取消按鈕
        root.addView(Button(ctx).apply {
            text = "取消"
            setOnClickListener { cancelAction?.invoke() }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).also {
                it.gravity = Gravity.CENTER_HORIZONTAL
                it.topMargin = (20 * dp).toInt()
            }
        })

        nfcDialog = BottomSheetDialog(ctx).apply {
            setContentView(root)
            setCancelable(false)
        }
        try {
            nfcDialog?.show()
            Log.i(NFC_LOG_TAG, "NFC BottomSheetDialog shown successfully")
        } catch (e: Exception) {
            Log.e(NFC_LOG_TAG, "NFC dialog show failed: ${e.message}", e)
            nfcDialog = null
        }
    }

    private fun dismissNfcDialog() {
        Log.d(NFC_LOG_TAG, "dismissNfcDialog")
        runCatching { nfcDialog?.dismiss() }
        nfcDialog = null
    }

    private fun buildSelectApdu(aid: ByteArray): ByteArray {
        return byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, aid.size.toByte()) + aid + byteArrayOf(0x00)
    }

    private fun wrapThrowable(error: Throwable): Throwable {
        return when {
            error is Messages.FlutterError -> error
            error is android.nfc.TagLostException ->
                Messages.FlutterError("nfc-tag-lost", "NFC connection lost. Keep your card steady against the device and try again", null)
            error is IOException && (error.message?.contains("transceive", ignoreCase = true) == true
                || error.message?.contains("tag", ignoreCase = true) == true
                || error.message?.contains("lost", ignoreCase = true) == true) ->
                Messages.FlutterError("nfc-tag-lost", "NFC connection lost. Keep your card steady against the device and try again", null)
            else -> Messages.FlutterError("nfc-io", error.message, null)
        }
    }
}

// ─── HdWalletApdu ────────────────────────────────────────────────────────────

internal object HdWalletApdu {
    val HD_WALLET_AID: ByteArray = byteArrayOf(
        0x68, 0x64, 0x69, 0x6E, 0x73, 0x74, 0x61, 0x63, 0x61, 0x73, 0x68, 0x00,
    )

    const val CLA: Byte = 0x80.toByte()
    const val INS_GET_VERSION: Byte = 0x30
    const val INS_GET_STATUS: Byte = 0x31
    const val INS_GENERATE_KEY: Byte = 0x41
    const val INS_DERIVE: Byte = 0x42
    const val INS_SIGN: Byte = 0x43
    const val INS_HAS_KEY: Byte = 0x47
    // PIN 管理（与 card_coin CreatePinRunnable/UpdatePinRunnable/UnlockCardRunnable/CancelPinRunnable 对应）
    const val INS_CREATE_PIN: Byte = 0x50   // 设置 PIN，响应含 PUK
    const val INS_UPDATE_PIN: Byte = 0x51   // 修改 PIN（旧PIN + 新PIN）
    const val INS_UNLOCK: Byte = 0x52       // PUK 解锁（PUK + 新PIN）
    const val INS_CANCEL_PIN: Byte = 0x57   // 取消/移除 PIN（PIN + PUK）
    const val TAG_PIN_CODE: Int = 0x95      // PIN 数据 TLV tag
    const val TAG_PUK_CODE: Int = 0x96      // PUK 数据 TLV tag
    // NDEF 域名读/写（与 card_coin GetNdefDataRunnable / StoreNdefDataRunnable 对应）
    const val INS_GET_NDEF: Byte = 0x62
    const val INS_STORE_NDEF: Byte = 0x63
    const val TAG_NDEF_URL: Int = 0x9B
    // UID 同步写入（与 card_coin StoreUidDataRunnable 对应）
    const val INS_STORE_UID: Byte = 0x65
    const val TAG_UID_STORE: Int = 0xA5

    const val TAG_PUBLIC_KEY: Int = 0x90
    const val TAG_PRIVATE_KEY: Int = 0x91
    const val TAG_CHAIN_CODE: Int = 0x92
    const val TAG_SIGN_MESSAGE: Int = 0x93
    const val TAG_DERIVE_PATH: Int = 0x94
    const val TAG_SIGNATURE: Int = 0x98
    const val TAG_HAS_KEY_PAIR: Int = 0x99
    const val TAG_PIN_SET: Int = 0x9A
    const val TAG_PIN_RETRY: Int = 0x9C
    const val TAG_PUK_RETRY: Int = 0x9D
    const val TAG_APPLET_VERSION: Int = 0xA0
    /** 卡片主密钥材料（状态响应 0xA1 tag）；全零表示密钥未真正初始化 */
    const val TAG_MASTER_KEY_MATERIAL: Int = 0xA1
    const val TAG_APPLET_VERSION_CODE: Int = 0xA2
    const val TAG_RESET_COUNT: Int = 0xA4
    const val TAG_UID: Int = 0xA5

    fun simple(ins: Byte): ByteArray = byteArrayOf(CLA, ins, 0x00, 0x00)

    fun withData(ins: Byte, data: ByteArray): ByteArray = byteArrayOf(CLA, ins, 0x00, 0x00, data.size.toByte()) + data

    fun tlv(tag: Int, value: ByteArray): ByteArray = byteArrayOf(tag.toByte(), value.size.toByte()) + value
}

// ─── HdWalletCardClient ───────────────────────────────────────────────────────

internal class HdWalletCardClient(
    private val isoDep: IsoDep,
    tagId: ByteArray,
    selectKeyBytes: ByteArray,
) {
    val cardId: String = tagId.toHex()
    private val tagIdBytes: ByteArray = tagId

    /** 每个 NFC session 内只查一次 PIN 状态，避免多次 UTXO 循环重复 getStatus */
    private var pinStatusChecked: Boolean = false
    private var cardHasPin: Boolean = false

    /**
     * 与 card_coin 一致：会话 AES 密钥 = SELECT 响应数据 + 卡 UID 前 4 字节
     * 模式 AES-128-CBC，IV = key（首 16 字节）
     * 使用 var 是因为卡片内部状态重置（INS=0x41）后需要重新 SELECT 刷新会话密钥
     */
    private var aesKey: ByteArray = (selectKeyBytes + tagId.copyOfRange(0, minOf(4, tagId.size))).also {
        Log.d("ChipCoreNfc", "HdWalletCardClient sessionKey [${it.size}] ${it.toHex()}")
    }

    fun getStatus(): CardStatus {
        val raw = send(HdWalletApdu.simple(HdWalletApdu.INS_GET_STATUS), "读取卡状态失败", skipReselect = true)
        val payload = parseStatusResponse(raw)
        val keyFlagSet = payload[HdWalletApdu.TAG_HAS_KEY_PAIR]?.firstOrNull() == 0x01.toByte()
        val versionCodeInt = payload[HdWalletApdu.TAG_APPLET_VERSION_CODE]
            ?.toString(StandardCharsets.UTF_8)?.toIntOrNull() ?: 99
        val uidBytes = payload[HdWalletApdu.TAG_UID] ?: byteArrayOf()
        val isNxpCard = uidBytes.size == 7
        val masterKeyIsValid = true
        val status = CardStatus(
            hasKeyPair = keyFlagSet && masterKeyIsValid,
            masterKeyFlagSet = keyFlagSet,
            pinSet = payload[HdWalletApdu.TAG_PIN_SET]?.firstOrNull() == 0x01.toByte(),
            uid = payload[HdWalletApdu.TAG_UID],
            version = payload[HdWalletApdu.TAG_APPLET_VERSION]?.toString(StandardCharsets.UTF_8),
            versionCode = payload[HdWalletApdu.TAG_APPLET_VERSION_CODE]?.toString(StandardCharsets.UTF_8),
            resetCount = payload[HdWalletApdu.TAG_RESET_COUNT]?.toLongValue() ?: 0L,
            pinRetry = payload[HdWalletApdu.TAG_PIN_RETRY]?.firstOrNull()?.toInt()?.and(0xFF) ?: 3,
            pukRetry = payload[HdWalletApdu.TAG_PUK_RETRY]?.firstOrNull()?.toInt()?.and(0xFF) ?: 5,
        )
        Log.d("ChipCoreNfc", "getStatus => hasKeyPair=${status.hasKeyPair}" +
            " masterKeyFlagSet=${status.masterKeyFlagSet}" +
            " masterKeyIsValid=$masterKeyIsValid" +
            " isNxpCard=$isNxpCard" +
            " pinSet=${status.pinSet}" +
            " pinRetry=${status.pinRetry}" +
            " pukRetry=${status.pukRetry}" +
            " isLock=${status.isLock}" +
            " uid=${status.uid?.toHex()}" +
            " version=${status.version}" +
            " versionCode=${status.versionCode}" +
            " resetCount=${status.resetCount}")
        return status
    }

    fun getOrCreateMasterKey(generateIfMissing: Boolean): KeyMaterial = generateKeyPair()

    fun generateKeyPair(): KeyMaterial {
        val payload = parseResponse(send(HdWalletApdu.simple(HdWalletApdu.INS_GENERATE_KEY), "生成密钥失败", skipReselect = true))
        return payload.toKeyMaterial()
    }

    fun deriveKeyAfterGenerate(path: ByteArray): KeyMaterial {
        // NXP 卡 flash 写入异步完成，等待写入结束后再派生，避免 SW=0005
        Thread.sleep(500)
        Log.d("ChipCoreNfc", "deriveKeyAfterGenerate path (raw) [${path.size}] ${path.toHex()}")
        val response = parseResponse(send(HdWalletApdu.withData(HdWalletApdu.INS_DERIVE, path), "派生公钥失败", skipReselect = true))
        return response.toKeyMaterial()
    }

    fun reselect(aid: ByteArray) {
        try {
            val selectApdu = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, aid.size.toByte()) + aid + byteArrayOf(0x00)
            val response = isoDep.transceive(selectApdu)
            if (response.size >= 2) {
                val sw1 = response[response.size - 2].toInt() and 0xFF
                val sw2 = response[response.size - 1].toInt() and 0xFF
                if (sw1 == 0x90 && sw2 == 0x00) {
                    val newKeyBase = response.copyOf(response.size - 2)
                    aesKey = newKeyBase + tagIdBytes.copyOfRange(0, minOf(4, tagIdBytes.size))
                    Log.d("ChipCoreNfc", "reselect: 刷新 aesKey [${aesKey.size}] ${aesKey.toHex()}")
                    return
                }
            }
            Log.w("ChipCoreNfc", "reselect: SELECT 响应异常, size=${response.size}")
            throw IOException("reselect SELECT 响应异常")
        } catch (e: Exception) {
            Log.w("ChipCoreNfc", "reselect 失败: ${e.message}")
            throw e
        }
    }

    fun deriveKey(path: ByteArray): KeyMaterial {
        val payload = HdWalletApdu.tlv(HdWalletApdu.TAG_DERIVE_PATH, path)
        val response = parseResponse(send(HdWalletApdu.withData(HdWalletApdu.INS_DERIVE, payload), "派生公钥失败", skipReselect = true))
        return response.toKeyMaterial()
    }

    fun sign(path: ByteArray, digest: ByteArray, pinCode: ByteArray? = null): ByteArray {
        require(digest.size == 32) { "签名输入必须是 32 字节摘要" }
        // 首次签名时获取实时 PIN 状态（每 NFC session 仅一次），防止缓存过时
        if (!pinStatusChecked) {
            pinStatusChecked = true
            cardHasPin = getStatus().pinSet
            Log.d("ChipCoreNfc", "sign: realtime cardHasPin=$cardHasPin")
        }
        if (cardHasPin && pinCode == null) {
            throw Messages.FlutterError("pin-required", "Card PIN is set, please enter PIN to sign", null)
        }
        var payload = HdWalletApdu.tlv(HdWalletApdu.TAG_SIGN_MESSAGE, digest) +
            HdWalletApdu.tlv(HdWalletApdu.TAG_DERIVE_PATH, path)
        if (pinCode != null) {
            payload = payload + HdWalletApdu.tlv(HdWalletApdu.TAG_PIN_CODE, pinCode)
        }
        val response = parseResponse(send(HdWalletApdu.withData(HdWalletApdu.INS_SIGN, payload), "签名失败", skipReselect = true))
        return response[HdWalletApdu.TAG_SIGNATURE]
            ?: throw Messages.FlutterError("invalid-response", "签名响应缺少 0x98 标签", null)
    }

    fun sendCommand(command: ByteArray): ByteArray = send(command, "scanCardWithCommand 失败")

    fun writeNdefAndVerify(url: String): String {
        val urlBytes = url.toByteArray(StandardCharsets.UTF_8)
        val payload = HdWalletApdu.tlv(HdWalletApdu.TAG_NDEF_URL, urlBytes)
        send(HdWalletApdu.withData(HdWalletApdu.INS_STORE_NDEF, payload), "写入 NDEF 失败")
        Log.d("ChipCoreNfc", "writeNdef: sent url=$url")

        val readBack = readNdef()
        if (readBack == url) {
            Log.d("ChipCoreNfc", "writeNdef: ✅ 验证成功，卡片存储=$readBack")
        } else {
            Log.w("ChipCoreNfc", "writeNdef: ⚠️ 验证不一致，期望=$url，卡片存储=$readBack")
        }
        return readBack
    }

    fun writeNdef(url: String) {
        val urlBytes = url.toByteArray(StandardCharsets.UTF_8)
        val payload = HdWalletApdu.tlv(HdWalletApdu.TAG_NDEF_URL, urlBytes)
        send(HdWalletApdu.withData(HdWalletApdu.INS_STORE_NDEF, payload), "写入 NDEF 失败")
        Log.d("ChipCoreNfc", "writeNdef: stored url=$url")
    }

    fun readNdef(): String {
        val raw = send(HdWalletApdu.simple(HdWalletApdu.INS_GET_NDEF), "读取 NDEF 失败")
        Log.d("ChipCoreNfc", "readNdef raw [${raw.size}] ${raw.toHex()}")
        if (raw.size < 2) return ""
        val tag = raw[0].toInt() and 0xFF
        val len = raw[1].toInt() and 0xFF
        if (tag != HdWalletApdu.TAG_NDEF_URL || raw.size < 2 + len) return ""
        return String(raw, 2, len, StandardCharsets.UTF_8)
    }

    fun writeUid() {
        val uid = cardId.hexToByteArrayOrNull() ?: return
        // SW=AC01 是应用层响应，applet 仍处于已选中状态，无需 reselect 直接发送即可
        val payload = byteArrayOf(HdWalletApdu.TAG_UID_STORE.toByte(), uid.size.toByte()) + uid
        val apdu = HdWalletApdu.withData(HdWalletApdu.INS_STORE_UID, payload)
        val raw = isoDep.transceive(apdu)
        Log.d("ChipCoreNfc", "writeUid SEND [${apdu.size}] ${apdu.toHex()}")
        Log.d("ChipCoreNfc", "writeUid RECV [${raw.size}] ${raw.toHex()}")
        ensureSuccessStatus(raw, "写入 UID 失败")
        Log.d("ChipCoreNfc", "writeUid: stored uid=${cardId}")
    }

    private fun send(apdu: ByteArray, context: String, skipReselect: Boolean = false): ByteArray {
        if (!skipReselect) reselect(HdWalletApdu.HD_WALLET_AID)

        // Case 1：无数据（getStatus、generateKeyPair），直接发送
        // Case 3/4：有数据时，若会话密钥已建立则先加密数据再发送（NXP 卡要求命令数据也需 AES 加密）
        val actualApdu: ByteArray
        if (apdu.size > 4 && aesKey.isNotEmpty()) {
            val plainData = apdu.copyOfRange(5, apdu.size)
            Log.d("ChipCoreNfc", "PLAIN [${plainData.size}] ${plainData.toHex()}")
            val encData = encryptAesCbc(plainData, aesKey)
            actualApdu = apdu.copyOf(4) + byteArrayOf(encData.size.toByte()) + encData + byteArrayOf(0x00)
        } else if (apdu.size > 4) {
            if (apdu.size > 5) {
                Log.d("ChipCoreNfc", "PLAIN [${apdu.size - 5}] ${apdu.copyOfRange(5, apdu.size).toHex()}")
            }
            actualApdu = apdu + byteArrayOf(0x00)
        } else {
            actualApdu = apdu
        }
        Log.d("ChipCoreNfc", "SEND [${actualApdu.size}] ${actualApdu.toHex()}")
        val response = isoDep.transceive(actualApdu)
        Log.d("ChipCoreNfc", "RECV [${response.size}] ${response.toHex()}")
        ensureSuccessStatus(response, context)
        val body = response.copyOf(response.size - 2)
        if (body.isEmpty() || aesKey.isEmpty()) return body
        val decrypted = decryptAesCbc(body, aesKey)
        Log.d("ChipCoreNfc", "DECR [${decrypted.size}] ${decrypted.toHex()}")
        return decrypted
    }

    /** AES-128-CBC 加密，IV = key，使用 PKCS7 填充（与卡片解密端保持一致） */
    private fun encryptAesCbc(data: ByteArray, key: ByteArray): ByteArray {
        val padLen = 16 - (data.size % 16)
        val padded = data + ByteArray(padLen) { padLen.toByte() }
        return try {
            val cipher = javax.crypto.Cipher.getInstance("AES/CBC/NoPadding")
            cipher.init(
                javax.crypto.Cipher.ENCRYPT_MODE,
                javax.crypto.spec.SecretKeySpec(key, "AES"),
                javax.crypto.spec.IvParameterSpec(key),
            )
            cipher.doFinal(padded)
        } catch (e: Exception) {
            Log.e("ChipCoreNfc", "AES encrypt failed: ${e.message}")
            data
        }
    }

    /** AES-128-CBC 解密，IV = key；自动剥离 PKCS7 填充和尾部零字节 */
    private fun decryptAesCbc(data: ByteArray, key: ByteArray): ByteArray {
        return try {
            val cipher = javax.crypto.Cipher.getInstance("AES/CBC/NoPadding")
            cipher.init(
                javax.crypto.Cipher.DECRYPT_MODE,
                javax.crypto.spec.SecretKeySpec(key, "AES"),
                javax.crypto.spec.IvParameterSpec(key),
            )
            var result = cipher.doFinal(data)
            // 剥离 PKCS7 填充：最后一字节值即为填充字节数
            if (result.isNotEmpty()) {
                val padLen = result.last().toInt() and 0xFF
                if (padLen in 1..16 && result.size >= padLen &&
                    result.takeLast(padLen).all { it == padLen.toByte() }
                ) {
                    result = result.copyOf(result.size - padLen)
                    Log.d("ChipCoreNfc", "PKCS7 stripped $padLen bytes")
                }
            }
            result
        } catch (e: Exception) {
            Log.e("ChipCoreNfc", "AES decrypt failed: ${e.message}")
            data
        }
    }

    private fun parseStatusResponse(payload: ByteArray): Map<Int, ByteArray> {
        Log.d("ChipCoreNfc", "parseStatusResponse [${payload.size}] ${payload.toHex()}")
        val map = linkedMapOf<Int, ByteArray>()
        val knownTags = intArrayOf(
            HdWalletApdu.TAG_HAS_KEY_PAIR,        // 0x99 hasKeyPair/isActivated
            HdWalletApdu.TAG_PIN_SET,              // 0x9A pinSet
            HdWalletApdu.TAG_PIN_RETRY,            // 0x9C pinRemaining
            HdWalletApdu.TAG_PUK_RETRY,            // 0x9D pukRemaining
            0x9E,                                  // isLocked
            0x9F,                                  // isDisabled
            HdWalletApdu.TAG_APPLET_VERSION,       // 0xA0 version string
            0xA1,                                  // signTimes
            HdWalletApdu.TAG_APPLET_VERSION_CODE,  // 0xA2 versionCode string
            0xA3,                                  // exportTimes
            HdWalletApdu.TAG_RESET_COUNT,          // 0xA4 resetCount
            HdWalletApdu.TAG_UID,                  // 0xA5 uid
            0xA6,                                  // hdTapTimes (optional)
        )
        for (tag in knownTags) {
            val idx = payload.indexOfFirst { (it.toInt() and 0xFF) == tag }
            if (idx == -1 || idx + 1 >= payload.size) continue
            val len = payload[idx + 1].toInt() and 0xFF
            val end = idx + 2 + len
            if (end > payload.size) {
                Log.w("ChipCoreNfc", "  tag=0x${tag.toString(16).uppercase()} len=$len 越界 (payload=${payload.size}), 跳过")
                continue
            }
            val value = payload.copyOfRange(idx + 2, end)
            map[tag] = value
            Log.d("ChipCoreNfc", "  tag=0x${tag.toString(16).uppercase().padStart(2,'0')} len=$len val=${value.toHex()}")
        }
        return map
    }

    private fun parseResponse(payload: ByteArray): Map<Int, ByteArray> {
        Log.d("ChipCoreNfc", "parseResponse [${payload.size}] ${payload.toHex()}")
        val map = linkedMapOf<Int, ByteArray>()
        var offset = 0
        while (offset < payload.size) {
            if (offset + 1 > payload.size) break
            val tag = payload[offset].toInt() and 0xFF
            offset++

            if (tag == 0x00) break

            if (offset >= payload.size) break
            val lenByte = payload[offset].toInt() and 0xFF
            offset++
            val length: Int = when {
                lenByte <= 0x7F -> lenByte
                lenByte == 0x81 -> {
                    if (offset >= payload.size)
                        throw Messages.FlutterError("invalid-response", "BER-TLV 0x81 长度字段不完整", null)
                    val l = payload[offset].toInt() and 0xFF
                    offset++
                    l
                }
                lenByte == 0x82 -> {
                    if (offset + 1 >= payload.size)
                        throw Messages.FlutterError("invalid-response", "BER-TLV 0x82 长度字段不完整", null)
                    val l = ((payload[offset].toInt() and 0xFF) shl 8) or (payload[offset + 1].toInt() and 0xFF)
                    offset += 2
                    l
                }
                else -> throw Messages.FlutterError(
                    "invalid-response",
                    "不支持的 TLV 长度格式 0x${lenByte.toString(16).uppercase()}",
                    null,
                )
            }

            val end = offset + length
            if (end > payload.size) {
                throw Messages.FlutterError(
                    "invalid-response",
                    "TLV 长度越界: tag=0x${tag.toString(16).uppercase()}, length=$length, remaining=${payload.size - offset}",
                    null,
                )
            }
            map[tag] = payload.copyOfRange(offset, end)
            offset = end
        }
        return map
    }
}
