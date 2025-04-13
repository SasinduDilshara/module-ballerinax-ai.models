// Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org).
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerinax/azure.openai.chat;
import ballerina/url;

const JSON_CONVERSION_ERROR = "FromJsonStringError";
const CONVERSION_ERROR = "ConversionError";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the LLM as the expected type. Retrying and/or validating the prompt could fix the response.";

# Configuration for Azure OpenAI model.
public type AzureOpenAIModelConfig record {|
    # Connection configuration for the Azure OpenAI model.
    chat:ConnectionConfig connectionConfig;
    # Service URL for the Azure OpenAI model.
    string serviceUrl;
|};

type ChatCompletionAzureRequest record {
    record {
        "user"|"system" role;
        string content;
    }[] messages = [];
    AzureOpenAIResponseFormat response_format;
};

type ChatCompletionRequest record {
    string prompt;
    AzureOpenAIResponseFormat responseFormat;
};

type AzureOpenAIResponseFormat ResponseFormatJsonSchema;

type ResponseFormatJsonSchema record {|
    "json_schema" 'type;
    ResponseFormatJsonSchemaValue json_schema;
|};

type ResponseFormatJsonSchemaValue record {|
    string description?;
    string name;
    json schema?;
    boolean? strict = true;
|};

type ChatCompletionAzureResponse record {
    AzureOpenAIResponseMessage[] choices?;
};

type AzureOpenAIResponseMessage record {
    record {
        string? content;
    } message;
};

# Azure OpenAI model chat completion client.
public isolated distinct client class AzureOpenAIModel {
    *Model;

    private final string deploymentId;
    private final string apiVersion;
    private final string apiKey;
    private final http:Client azureOpenAIClient;

    public isolated function init(AzureOpenAIModelConfig azureOpenAI,
            string deploymentId,
            string apiVersion) returns error? {
        self.deploymentId = deploymentId;
        self.apiVersion = apiVersion;
        http:BearerTokenConfig|chat:ApiKeysConfig auth = azureOpenAI.connectionConfig.auth;

        if auth is http:BearerTokenConfig {
            self.apiKey = auth.token;
        } else {
            self.apiKey = auth.apiKey;
        }

        self.azureOpenAIClient = check generateHttpClientFromAzureOpenAIModelConfig(azureOpenAI);
    }

    isolated remote function call(string prompt, map<json> expectedResponseSchema) returns json|error {
        ChatCompletionAzureRequest chatBody = {
            messages: [{role: "user", "content": getPromptWithExpectedResponseSchema(prompt, expectedResponseSchema)}],
            response_format: check getJsonSchemaResponseFormatForAzureOpenAI(expectedResponseSchema)
        };

        ChatCompletionAzureResponse|error chatResult =
            self.azureOpenAIClient->/deployments/[getEncodedUri(self.deploymentId)]/chat/completions.post(
                chatBody,
                {api\-key: self.apiKey},
                api\-version = self.apiVersion
            );

        if chatResult is error {
            return error("Chat completion failed", chatResult);
        }

        AzureOpenAIResponseMessage[]? choices = chatResult.choices;

        if choices is () {
            return error("No completion message");
        }

        string? resp = choices[0].message?.content;
        if resp is () {
            return error("No completion message");
        }
        return parseResponseAsJson(resp);
    }
}

isolated function getJsonSchemaResponseFormatForAzureOpenAI(map<json> schema) returns AzureOpenAIResponseFormat|error {
    return getJsonSchemaResponseFormatForModel(schema).cloneWithType();
}

isolated function generateHttpClientFromAzureOpenAIModelConfig(AzureOpenAIModelConfig azureOpenAI)
        returns http:Client|error {
    chat:ConnectionConfig config = azureOpenAI.connectionConfig;
    http:ClientConfiguration httpClientConfig = {
        httpVersion: config.httpVersion,
        timeout: config.timeout,
        forwarded: config.forwarded,
        poolConfig: config.poolConfig,
        compression: config.compression,
        circuitBreaker: config.circuitBreaker,
        retryConfig: config.retryConfig,
        validation: config.validation
    };

    if config.http1Settings is chat:ClientHttp1Settings {
        chat:ClientHttp1Settings settings = check config.http1Settings.ensureType();
        httpClientConfig.http1Settings = {...settings};
    }
    if config.http2Settings is http:ClientHttp2Settings {
        httpClientConfig.http2Settings = check config.http2Settings.ensureType();
    }
    if config.cache is http:CacheConfig {
        httpClientConfig.cache = check config.cache.ensureType();
    }
    if config.responseLimits is http:ResponseLimitConfigs {
        httpClientConfig.responseLimits = check config.responseLimits.ensureType();
    }
    if config.secureSocket is http:ClientSecureSocket {
        httpClientConfig.secureSocket = check config.secureSocket.ensureType();
    }
    if config.proxy is http:ProxyConfig {
        httpClientConfig.proxy = check config.proxy.ensureType();
    }

    return new (azureOpenAI.serviceUrl, httpClientConfig);
}

isolated function parseResponseAsJson(string resp) returns json|error {
    int startDelimLength = 7;
    int? startIndex = resp.indexOf("```json");
    if startIndex is () {
        startIndex = resp.indexOf("```");
        startDelimLength = 3;
    }
    int? endIndex = resp.lastIndexOf("```");

    string processedResponse = startIndex is () || endIndex is () ?
        resp :
        resp.substring(startIndex + startDelimLength, endIndex).trim();
    json|error result = trap processedResponse.fromJsonString();
    if result is error {
        return handlepParseResponseError(result);
    }
    return result;
}

isolated function parseResponseAsType(json resp, typedesc<json> targetType) returns json|error {
    json|error result = trap resp.fromJsonWithType(targetType);
    if result is error {
        return handlepParseResponseError(result);
    }
    return result;
}

isolated function handlepParseResponseError(error chatResponseError) returns error {
    if chatResponseError.message().includes(JSON_CONVERSION_ERROR)
            || chatResponseError.message().includes(CONVERSION_ERROR) {
        return error(string `${ERROR_MESSAGE}`, detail = chatResponseError);
    }
    return chatResponseError;
}

isolated function getJsonSchemaResponseFormatForModel(map<json> schema) returns map<json> {
    return {
        'type: "json_schema",
        json_schema: {
            name: "LlmResponseSchema",
            schema,
            strict: false
        }
    };
}

isolated function getEncodedUri(anydata value) returns string {
    string|error encoded = url:encode(value.toString(), "UTF8");
    return encoded is string ? encoded : value.toString();
}

isolated function getPromptWithExpectedResponseSchema(string prompt, map<json> expectedResponseSchema) returns string =>
    string `${prompt}.  
        The output should be a JSON value that satisfies the following JSON schema, 
        returned within a markdown snippet enclosed within ${"```json"} and ${"```"}
        
        Schema:
        ${expectedResponseSchema.toJsonString()}`;
