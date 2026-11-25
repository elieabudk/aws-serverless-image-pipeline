import { randomUUID } from "node:crypto";
import { S3Client } from "@aws-sdk/client-s3";
import { createPresignedPost } from "@aws-sdk/s3-presigned-post";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

const s3Client = new S3Client({});
const ddbDocClient = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const SOURCE_BUCKET = process.env.SOURCE_BUCKET;
const TABLE_NAME = process.env.TABLE_NAME;
// Allowlist mínima: solo los formatos que process-image (Jimp) sabe decodificar
const ALLOWED_MIME_TYPES = new Set(["image/jpeg", "image/png"]);
const URL_EXPIRATION_SECONDS = 300; // 5 minutos
const MAX_FILE_SIZE_BYTES = 5 * 1024 * 1024; // 5 MB máximo
const PENDING_TTL_SECONDS = 24 * 60 * 60; // TTL de DynamoDB: el registro expira si no se completa en 24 h

const buildResponse = (statusCode, body) => ({
  statusCode,
  headers: {
    "Content-Type": "application/json",
    "X-Content-Type-Options": "nosniff",
  },
  body: JSON.stringify(body),
});

export const handler = async (event) => {
  try {
    if (!event.body) {
      return buildResponse(400, { error: "El cuerpo de la petición es obligatorio." });
    }

    // API Gateway (HTTP API) envía el body en base64 si la petición no es application/json
    const rawBody = event.isBase64Encoded
      ? Buffer.from(event.body, "base64").toString("utf8")
      : event.body;

    let payload;
    try {
      payload = JSON.parse(rawBody);
    } catch {
      return buildResponse(400, { error: "El formato JSON no es válido." });
    }

    if (!payload || typeof payload !== "object") {
      return buildResponse(400, { error: "El cuerpo debe ser un objeto JSON." });
    }

    const { fileName, contentType } = payload;

    if (!fileName || typeof fileName !== "string" || !contentType) {
      return buildResponse(400, {
        error: "Los campos 'fileName' y 'contentType' son obligatorios.",
      });
    }

    if (!ALLOWED_MIME_TYPES.has(contentType)) {
      return buildResponse(415, {
        error: "Tipo de archivo no soportado. Usa image/jpeg o image/png.",
      });
    }

    const sanitizedFileName = fileName
      .replace(/[^a-zA-Z0-9._-]/g, "_")
      .slice(-50);

    const imageId = randomUUID();
    const objectKey = `uploads/${imageId}-${sanitizedFileName}`;
    const createdAt = new Date().toISOString();

    await ddbDocClient.send(
      new PutCommand({
        TableName: TABLE_NAME,
        Item: {
          imageId,
          originalKey: objectKey,
          contentType,
          status: "PENDING",
          createdAt,
          updatedAt: createdAt,
          expiresAt: Math.floor(Date.now() / 1000) + PENDING_TTL_SECONDS,
        },
        ConditionExpression: "attribute_not_exists(imageId)",
      })
    );

    // Generar Presigned POST con límite estricto de tamaño (1 byte a 5 MB)
    const { url, fields } = await createPresignedPost(s3Client, {
      Bucket: SOURCE_BUCKET,
      Key: objectKey,
      Conditions: [
        ["content-length-range", 1, MAX_FILE_SIZE_BYTES],
        ["eq", "$Content-Type", contentType],
      ],
      Fields: {
        "Content-Type": contentType,
      },
      Expires: URL_EXPIRATION_SECONDS,
    });

    console.info(JSON.stringify({ level: "INFO", message: "Presigned POST generado", imageId }));

    return buildResponse(201, {
      imageId,
      objectKey,
      uploadUrl: url,
      fields,
      maxSizeBytes: MAX_FILE_SIZE_BYTES,
      expiresIn: URL_EXPIRATION_SECONDS,
    });
  } catch (error) {
    console.error(JSON.stringify({ level: "ERROR", message: error.message, stack: error.stack }));
    return buildResponse(500, { error: "Error interno al generar la URL de subida." });
  }
};
