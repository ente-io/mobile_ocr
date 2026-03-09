package io.ente.mobile_ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

/** MobileOcrPlugin */
class MobileOcrPlugin: FlutterPlugin, MethodCallHandler {
  companion object {
    private const val TAG = "MobileOcrPlugin"
    private const val QUICK_DETECTION_MIN_SCORE = 0.9f
  }

  private lateinit var channel : MethodChannel
  private lateinit var context: Context
  private var ocrProcessor: OcrProcessor? = null
  private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
  private lateinit var modelManager: ModelManager
  private var cachedModelFiles: ModelFiles? = null
  private val modelMutex = Mutex()
  private val processorMutex = Mutex()
  private val displayableCacheMutex = Mutex()
  private val displayableImageCache = mutableMapOf<String, ImageCacheEntry>()
  private val activeTasks = AtomicInteger(0)
  @Volatile private var shuttingDown = false

  private data class ImageCacheEntry(
    val cachedPath: String,
    val sourceModified: Long,
    val sourceSize: Long
  )

  private val transcodableExtensions = setOf("heic", "heif", "heics", "avif")

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "mobile_ocr")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext
    modelManager = ModelManager(context)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "prepareModels" -> {
        mainScope.launch {
          try {
            val modelFiles = withContext(Dispatchers.IO) { getModelFiles() }
            withContext(Dispatchers.IO) {
              processorMutex.withLock {
                if (ocrProcessor == null) {
                  ocrProcessor = OcrProcessor(context, modelFiles)
                }
              }
            }
            result.success(
              mapOf(
                "isReady" to true,
                "version" to modelFiles.version,
                "modelPath" to modelFiles.baseDir.absolutePath
              )
            )
          } catch (e: Exception) {
            Log.e(TAG, "Model preparation failed", e)
            result.error("MODEL_PREP_ERROR", e.message ?: "Could not prepare models", null)
          }
        }
      }
      "detectText" -> {
        val imagePath = call.argument<String>("imagePath")
        if (imagePath.isNullOrBlank()) {
          result.error("INVALID_ARGUMENT", "Image path is required", null)
          return
        }

        val includeAllConfidenceScores = call.argument<Boolean>("includeAllConfidenceScores") ?: false

        mainScope.launch {
          try {
            val ocrResult = withContext(Dispatchers.IO) {
              processImage(imagePath, includeAllConfidenceScores)
            }
            result.success(ocrResult)
          } catch (e: Exception) {
            Log.e(TAG, "OCR processing failed for $imagePath", e)
            result.error("OCR_ERROR", e.message ?: "Could not process image", null)
          }
        }
      }
      "hasText" -> {
        val imagePath = call.argument<String>("imagePath")
        if (imagePath.isNullOrBlank()) {
          result.error("INVALID_ARGUMENT", "Image path is required", null)
          return
        }

        mainScope.launch {
          try {
            val detectionSummary = withContext(Dispatchers.IO) {
              hasHighConfidenceText(imagePath, QUICK_DETECTION_MIN_SCORE)
            }
            val threshold = String.format(Locale.US, "%.2f", QUICK_DETECTION_MIN_SCORE)
            val maxScore = detectionSummary.maxDetectionScore?.let {
              String.format(Locale.US, "%.3f", it)
            } ?: "none"
            val bestRecognition = detectionSummary.bestRecognitionScore?.let {
              String.format(Locale.US, "%.3f", it)
            } ?: "none"
            val matchedDetectionScore = detectionSummary.matchedDetectionScore?.let {
              String.format(Locale.US, "%.3f", it)
            } ?: "none"
            Log.i(
              TAG,
              "hasText quick check result=${detectionSummary.hasText}; " +
                "detectorHit=${detectionSummary.detectorHit} threshold=$threshold " +
                "examined=${detectionSummary.examinedDetections} candidates=${detectionSummary.candidateCount} " +
                "evaluated=${detectionSummary.evaluatedCandidates} maxScore=$maxScore " +
                "bestRec=$bestRecognition matchedScore=$matchedDetectionScore"
            )
            result.success(detectionSummary.hasText)
          } catch (e: Exception) {
            Log.e(TAG, "Quick detection failed for $imagePath", e)
            result.error("DETECTION_ERROR", e.message ?: "Could not analyze image", null)
          }
        }
      }
      "getPlatformVersion" -> {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
      }
      "ensureImageIsDisplayable" -> {
        val imagePath = call.argument<String>("imagePath")
        if (imagePath.isNullOrBlank()) {
          result.error("INVALID_ARGUMENT", "Image path is required", null)
          return
        }
        mainScope.launch {
          try {
            val resolvedPath = withContext(Dispatchers.IO) {
              ensureImageIsDisplayable(imagePath)
            }
            result.success(resolvedPath)
          } catch (e: Exception) {
            Log.e(TAG, "Failed to prepare displayable image for $imagePath", e)
            result.error("IMAGE_DECODE_ERROR", e.message ?: "Could not decode image", null)
          }
        }
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  private suspend fun processImage(imagePath: String, includeAllConfidenceScores: Boolean = false): Map<String, Any> {
    if (shuttingDown) {
      throw IllegalStateException("Plugin is shutting down")
    }
    activeTasks.incrementAndGet()
    try {
      val processor = getOrCreateProcessor()

      val file = java.io.File(imagePath)
      if (!file.exists()) {
        throw IllegalArgumentException("Image file does not exist at path: $imagePath")
      }

      val bitmap = BitmapFactory.decodeFile(imagePath)
          ?: throw IllegalArgumentException("Failed to decode image at path: $imagePath")
      val correctedBitmap = applyExifOrientation(bitmap, imagePath)

      val imageWidth = correctedBitmap.width
      val imageHeight = correctedBitmap.height

      // Process with OCR
      val ocrResults = processor.processImage(correctedBitmap, includeAllConfidenceScores)
      if (correctedBitmap !== bitmap && !bitmap.isRecycled) {
        bitmap.recycle()
      }
      if (!correctedBitmap.isRecycled) {
        correctedBitmap.recycle()
      }

      if (ocrResults.texts.isEmpty()) {
        return hashMapOf(
          "blocks" to emptyList<Map<String, Any>>(),
          "imageWidth" to imageWidth,
          "imageHeight" to imageHeight
        )
      }

      val blocks = ocrResults.boxes.mapIndexed { index, box ->
        val pointMaps: List<Map<String, Double>> = box.points.map { point ->
          mapOf(
            "x" to point.x.toDouble(),
            "y" to point.y.toDouble()
          )
        }
        val characterMaps: List<Map<String, Any>> = ocrResults.characters.getOrNull(index)?.map { character ->
          mapOf<String, Any>(
            "text" to character.text,
            "confidence" to character.confidence.toDouble(),
            "points" to character.points.map { charPoint ->
              mapOf(
                "x" to charPoint.x.toDouble(),
                "y" to charPoint.y.toDouble()
              )
            }
          )
        } ?: emptyList()

        hashMapOf<String, Any>(
          "text" to ocrResults.texts[index],
          "confidence" to ocrResults.scores[index].toDouble(),
          "points" to pointMaps,
          "characters" to characterMaps
        )
      }

      return hashMapOf(
        "blocks" to blocks,
        "imageWidth" to imageWidth,
        "imageHeight" to imageHeight
      )
    } finally {
      activeTasks.decrementAndGet()
    }
  }

  private suspend fun hasHighConfidenceText(
    imagePath: String,
    minDetectionConfidence: Float
  ): QuickCheckResult {
    if (shuttingDown) {
      throw IllegalStateException("Plugin is shutting down")
    }
    activeTasks.incrementAndGet()
    try {
      val processor = getOrCreateProcessor()

      val file = java.io.File(imagePath)
      if (!file.exists()) {
        throw IllegalArgumentException("Image file does not exist at path: $imagePath")
      }

      val bitmap = BitmapFactory.decodeFile(imagePath)
        ?: throw IllegalArgumentException("Failed to decode image at path: $imagePath")
      val correctedBitmap = applyExifOrientation(bitmap, imagePath)

      val result = processor.hasHighConfidenceText(correctedBitmap, minDetectionConfidence)

      if (correctedBitmap !== bitmap && !bitmap.isRecycled) {
        bitmap.recycle()
      }
      if (!correctedBitmap.isRecycled) {
        correctedBitmap.recycle()
      }

      return result
    } finally {
      activeTasks.decrementAndGet()
    }
  }

  private fun ensureImageIsDisplayable(imagePath: String): String {
    val file = File(imagePath)
    if (!file.exists()) {
      throw IllegalArgumentException("Image file does not exist at path: $imagePath")
    }

    val extension = file.extension.lowercase(Locale.US)
    if (extension.isEmpty() || !transcodableExtensions.contains(extension)) {
      return imagePath
    }

    val lastModified = file.lastModified()
    val size = file.length()
    val cacheKey = file.absolutePath

    return runBlocking {
      displayableCacheMutex.withLock {
        displayableImageCache[cacheKey]?.let { entry ->
          val cachedFile = File(entry.cachedPath)
          if (
            entry.sourceModified == lastModified &&
            entry.sourceSize == size &&
            cachedFile.exists()
          ) {
            return@runBlocking entry.cachedPath
          }
        }

        val bitmap = BitmapFactory.decodeFile(imagePath)
            ?: throw IllegalArgumentException("Failed to decode image at path: $imagePath")
        val correctedBitmap = applyExifOrientation(bitmap, imagePath)

        val cacheDir = File(context.cacheDir, "mobile_ocr_display").apply {
          if (!exists()) {
            mkdirs()
          }
        }
        val digestInput = "$cacheKey:$lastModified:$size"
        val hash = MessageDigest.getInstance("MD5").digest(digestInput.toByteArray())
          .joinToString("") { "%02x".format(it) }
        val cacheFile = File(cacheDir, "img_$hash.png")

        FileOutputStream(cacheFile).use { stream ->
          val success = correctedBitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
          if (!success) {
            throw IllegalStateException("Failed to encode PNG for $imagePath")
          }
        }

        if (correctedBitmap !== bitmap && !bitmap.isRecycled) {
          bitmap.recycle()
        }
        if (!correctedBitmap.isRecycled) {
          correctedBitmap.recycle()
        }

        displayableImageCache[cacheKey] = ImageCacheEntry(
          cachedPath = cacheFile.absolutePath,
          sourceModified = lastModified,
          sourceSize = size
        )

        cacheFile.absolutePath
      }
    }
  }

  private fun applyExifOrientation(source: Bitmap, imagePath: String): Bitmap {
    return runCatching {
      val exif = ExifInterface(imagePath)
      val orientation = exif.getAttributeInt(
        ExifInterface.TAG_ORIENTATION,
        ExifInterface.ORIENTATION_NORMAL
      )

      val matrix = Matrix()
      var transformed = true
      when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
        ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
        ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
        ExifInterface.ORIENTATION_TRANSPOSE -> {
          matrix.postRotate(90f)
          matrix.preScale(-1f, 1f)
        }
        ExifInterface.ORIENTATION_TRANSVERSE -> {
          matrix.postRotate(270f)
          matrix.preScale(-1f, 1f)
        }
        else -> transformed = false
      }

      if (!transformed || matrix.isIdentity) {
        source
      } else {
        Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true).also {
          if (it != source && !source.isRecycled) {
            source.recycle()
          }
        }
      }
    }.getOrDefault(source)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    shuttingDown = true
    mainScope.cancel()
    runBlocking {
      withTimeoutOrNull(5_000) {
        while (activeTasks.get() > 0) {
          delay(50)
        }
      }
      processorMutex.withLock {
        ocrProcessor?.close()
        ocrProcessor = null
      }
      modelMutex.withLock {
        cachedModelFiles = null
      }
    }
    displayableImageCache.clear()
  }

  private suspend fun getModelFiles(): ModelFiles {
    return modelMutex.withLock {
      cachedModelFiles?.let { return@withLock it }
      val files = modelManager.ensureModels()
      cachedModelFiles = files
      files
    }
  }

  private suspend fun getOrCreateProcessor(): OcrProcessor {
    val modelFiles = getModelFiles()
    return processorMutex.withLock {
      ocrProcessor ?: OcrProcessor(context, modelFiles).also { created ->
        ocrProcessor = created
      }
    }
  }
}
