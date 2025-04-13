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

import ballerinax/openai.chat as openAIChat;
import ballerina/url;
import ballerina/http;

const JSON_CONVERSION_ERROR = "FromJsonStringError";
const CONVERSION_ERROR = "ConversionError";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the LLM as the expected type. Retrying and/or validating the prompt could fix the response.";

# Configuration for OpenAI model.
public type OpenAIModelConfig record {|
    # Connection configuration for the OpenAI model.
    openAIChat:ConnectionConfig connectionConfig;
    # Service URL for the OpenAI model.
    string serviceUrl?;
|};

type OpenAIResponseFormat
    openAIChat:ResponseFormatText|openAIChat:ResponseFormatJsonObject|openAIChat:ResponseFormatJsonSchema;

# OpenAI model chat completion client.
public isolated distinct client class OpenAIModel {
    *Model;

    private final openAIChat:Client cl;
    private final string model;

    public isolated function init(openAIChat:Client|OpenAIModelConfig openAI, string model) returns error? {
        self.cl = openAI is openAIChat:Client ?
            openAI :
            let string? serviceUrl = openAI?.serviceUrl in
                    serviceUrl is () ?
                    check new (openAI.connectionConfig) :
                    check new (openAI.connectionConfig, serviceUrl);
        self.model = model;
    }

    isolated remote function call(string prompt, map<json> expectedResponseSchema) returns json|error {
        OpenAIResponseFormat responseFormat = check getJsonSchemaResponseFormatForOpenAI(expectedResponseSchema);
        openAIChat:CreateChatCompletionRequest chatBody = {
            messages: [{role: "user", "content": getPromptWithExpectedResponseSchema(prompt, expectedResponseSchema)}],
            model: self.model,
            response_format: responseFormat
        };

        openAIChat:CreateChatCompletionResponse chatResult =
            check self.cl->/chat/completions.post(chatBody);
        openAIChat:CreateChatCompletionResponse_choices[] choices = chatResult.choices;

        string? resp = choices[0].message?.content;
        if resp is () {
            return error("No completion message");
        }
        return parseResponseAsJson(resp);
    }
}

isolated function getJsonSchemaResponseFormatForOpenAI(map<json> schema) returns OpenAIResponseFormat|error {
    return getJsonSchemaResponseFormatForModel(schema).cloneWithType();
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
