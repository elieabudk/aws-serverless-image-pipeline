import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { Jimp } from "jimp";

const s3Client = new S3Client({});
const ddbDocClient = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const DESTINATION_BUCKET = process.env.DESTINATION_BUCKET;
const TABLE_NAME = process.env.TABLE_NAME;
const THUMBNAIL_SIZE = 200;
const MAX_ALLOWED_SIZE = 5 * 1024 * 1024; // 5 MB, inclusive, igual que el presigned POST
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const isAllowedObjectSize = (size) =>
  typeof size === "number" && Number.isInteger(size) && size >= 1 && size <= MAX_ALLOWED_SIZE;

// Rechazo definitivo: no se relanza, para que SQS borre el mensaje y no lo reintente.
const markRejected = async (imageId, reason) => {
  console.error(JSON.stringify({ level: "ERROR", message: reason, imageId }));

  if (!UUID_PATTERN.test(imageId)) {
    return;
  }

  try {
    await ddbDocClient.send(
      new UpdateCommand({
        TableName: TABLE_NAME,
        Key: { imageId },
        UpdateExpression:
          "SET #status = :status, rejectionReason = :reason, updatedAt = :updatedAt",
        ConditionExpression: "attribute_exists(imageId)",
        ExpressionAttributeNames: {
          "#status": "status",
        },
        ExpressionAttributeValues: {
          ":status": "REJECTED",
          ":reason": reason,
          ":updatedAt": new Date().toISOString(),
        },
      })
    );
  } catch (error) {
    if (error.name === "ConditionalCheckFailedException") {
      console.error(
        JSON.stringify({
          level: "ERROR",
          message: "No existe el item para marcarlo como REJECTED",
          imageId,
        })
      );
      return;
    }
    throw error;
  }
};

export const handler = async (event) => {
  for (const sqsRecord of event.Records) {
    
    const s3Event = JSON.parse(sqsRecord.body);

    // Ignorar eventos de prueba iniciales de S3 (s3:TestEvent)
    if (s3Event.Event === "s3:TestEvent") {
      continue;
    }

    for (const record of s3Event.Records ?? []) {
      const sourceBucket = record.s3?.bucket?.name;
      const rawKey = record.s3?.object?.key;
      if (!sourceBucket || !rawKey) {
        throw new Error("Evento S3 sin bucket u object key.");
      }

      const sourceKey = decodeURIComponent(String(rawKey).replace(/\+/g, " "));

      // Extraer el imageId del patrón: uploads/<uuid>-<filename>
      const fileNamePart = sourceKey.split("/").pop() ?? "";
      const imageId = fileNamePart.slice(0, 36);

      try {
        const objectSize = record.s3?.object?.size;
        if (!isAllowedObjectSize(objectSize)) {
          await markRejected(
            imageId,
            `Tamaño no permitido (${objectSize} bytes). Admitido: 1 a ${MAX_ALLOWED_SIZE} bytes.`
          );
          continue;
        }

        // Paso 10: Leer la imagen original desde S3 Origen (vía VPC Gateway Endpoint)
        const getResponse = await s3Client.send(
          new GetObjectCommand({
            Bucket: sourceBucket,
            Key: sourceKey,
          })
        );

        const imageBytes = await getResponse.Body.transformToByteArray();
        const originalBuffer = Buffer.from(imageBytes);

        if (originalBuffer.length > MAX_ALLOWED_SIZE) {
          await markRejected(
            imageId,
            `Contenido descargado de ${originalBuffer.length} bytes; máximo ${MAX_ALLOWED_SIZE}.`
          );
          continue;
        }

        // Procesar imagen y extraer metadatos con Jimp
        const image = await Jimp.read(originalBuffer);
        const metadata = {
          originalWidth: image.width,
          originalHeight: image.height,
          originalSizeBytes: originalBuffer.length,
          mimeType: image.mime || "image/jpeg",
        };

        // Redimensionar a miniatura de 200x200 manteniendo proporción
        image.scaleToFit({ w: THUMBNAIL_SIZE, h: THUMBNAIL_SIZE });
        const thumbnailBuffer = await image.getBuffer(metadata.mimeType);

        const destinationKey = `thumbnails/thumb-${fileNamePart}`;

        // Paso 11: Guardar miniatura en S3 Destino (vía VPC Gateway Endpoint)
        await s3Client.send(
          new PutObjectCommand({
            Bucket: DESTINATION_BUCKET,
            Key: destinationKey,
            Body: thumbnailBuffer,
            ContentType: metadata.mimeType,
          })
        );

        // Paso 12: Actualizar estado a COMPLETED y metadatos en DynamoDB
        await ddbDocClient.send(
          new UpdateCommand({
            TableName: TABLE_NAME,
            Key: { imageId },
            UpdateExpression:
              "SET #status = :status, destinationKey = :destKey, metadata = :meta, updatedAt = :updatedAt REMOVE expiresAt",
            ConditionExpression: "attribute_exists(imageId)",
            ExpressionAttributeNames: {
              "#status": "status",
            },
            ExpressionAttributeValues: {
              ":status": "COMPLETED",
              ":destKey": destinationKey,
              ":meta": metadata,
              ":updatedAt": new Date().toISOString(),
            },
          })
        );

        console.info(
          JSON.stringify({
            level: "INFO",
            message: "Imagen procesada correctamente",
            imageId,
            destinationKey,
          })
        );
      } catch (error) {
        console.error(
          JSON.stringify({
            level: "ERROR",
            message: "Fallo procesando imagen; se delega reintento/DLQ a SQS",
            imageId,
            sourceKey,
            error: error.message,
          })
        );
        // Relanzar el error es vital para que SQS reintente y envíe a la DLQ si agota intentos
        throw error;
      }
    }
  }
};
