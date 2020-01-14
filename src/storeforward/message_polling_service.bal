// Copyright (c) 2019 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
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
import ballerina/log;
import ballerina/runtime;
import wso2/jms;


// Service executed when message processor is triggered
service messageForwardingService = service {

    resource function onTrigger(PollingServiceConfig config) {
        int messageCount = 0;
        while (config.batchSize == -1 || messageCount < config.batchSize) {
            ForwardStatus forwardStatus = pollAndForward(<@untainted>config);
            // Immediately return from the loop if there is no message on message store or if processor should get
            // deactivated on forwarding fail
            if(!forwardStatus.success && (config.forwardingFailAction == DEACTIVATE) || forwardStatus.storeEmpty) {
                if(forwardStatus.storeEmpty) {
                    log:printDebug("Message store is empty. Queue = " + config.queueName 
                    + ". Message forwarding is stopped until next trigger");
                }
                break;
            }
            if(config.forwardingInterval > 0) {
                runtime:sleep(config.forwardingInterval);
            }
            messageCount = messageCount + 1;
        }
    }
};

# Poll a message from message store and forward it to a defined endpoint.
#
# + config - Configuration for message processing service
# + return - `true` if message forwarding is successful
function pollAndForward(PollingServiceConfig config) returns ForwardStatus {
    boolean forwardSuccess = true;
    boolean messageStoreEmpty = false;
    function() onMessagePollingFailFunction = config.onMessagePollingFail;
    jms:MessageConsumer consumer = config.messageConsumer;
    //wait for 1 second until you receive a message. If no message is received nil is returned
    jms:Message|error? queueMessage = consumer->receive(1000);
    if (queueMessage is jms:BytesMessage) {
        http:Request|error httpRequest = constructHTTPRequest(queueMessage);
        if (httpRequest is http:Request) {
            // Invoke pre-process logic
            (function (http:Request) returns ())? preProcessRequest = config.preProcessRequest;
            if (preProcessRequest is function(http:Request request)) {
                preProcessRequest(httpRequest);
            }

            // Invoke the backend using HTTP Client, it will use resiliency parameters
            http:Client clientEP = config.httpClient;
            string httpVerb = config.HttpOperation;
            var response = clientEP->execute(<@untainted> httpVerb, "", httpRequest);
            forwardSuccess = evaluateForwardSuccess(config, httpRequest, response, queueMessage);
        } else {
            log:printError("Error occurred while converting message received from queue "
            + config.queueName + " to an HTTP request");
        }

    } else if (queueMessage is ()) {
        log:printDebug("Message not received on current trigger");
        forwardSuccess = false;
        messageStoreEmpty = true;
    } else {
        // Error on receiving message. Need to reset the connection, session and consumer
        log:printError("Error occurred while receiving message from queue " + config.queueName);
        forwardSuccess = false;
        onMessagePollingFailFunction();
    }

    ForwardStatus forwardStatus = {
        success: forwardSuccess,
        storeEmpty: messageStoreEmpty
    };

    return forwardStatus;
}

# Evaluate if HTTP response forwarding is success or failure and take actions. 
#
# + response - `http:Response` or `error` received from forwarding the message  
# + config - Message processor config `PollingServiceConfig` 
# + queueMessage - Message polled from the queue `jms:Message`
# + request - HTTP request forwarded `http:Request`
# + return - `true` if message forwarding is a success
function evaluateForwardSuccess(PollingServiceConfig config, http:Request request,
                http:Response|error response, jms:Message queueMessage) returns boolean {
    // If retry status codes are specified, HTTP client will retry but a response
    // will be received. Still, in case of forwarding we need to consider it as a failure.
    boolean forwardSucess = true;
    if (response is http:Response) {
        boolean isFailingResponse = false;
        int[] retryHTTPCodes = config.retryHttpCodes;
        if (retryHTTPCodes.length() > 0) {
            foreach var statusCode in retryHTTPCodes {
                if (statusCode == response.statusCode) {
                    isFailingResponse = true;
                    break;
                }
            }
        }
        if (isFailingResponse) {
            // Failure. Response has failure HTTP status code
            forwardSucess = false;
            onMessageForwardingFail(config, request, queueMessage);
        } else {
            // Success. Ack the message
            forwardSucess = true;
            jms:MessageConsumer consumer = config.messageConsumer;
            var ack = queueMessage->acknowledge();
            if (ack is error) {
                log:printError("Error occurred while acknowledging message", err = ack);
            }
            config.handleResponse(response);
        }
    } else {
        //Failure. Connection level issue
        forwardSucess = false;
        log:printError("Error when invoking the backend" + config.httpEP, err = response);
        onMessageForwardingFail(config, request, queueMessage);
    }
    return forwardSucess;
}

# Take actions when message forwarding fails. 
#
# + config - Configuration for message processor `PollingServiceConfig`
# + request - HTTP request `http:Request` failed to forward 
# + queueMessage - Message received from the queue `jms:Message` that failed to process
function onMessageForwardingFail(PollingServiceConfig config, http:Request request, jms:Message queueMessage) {
    if (config.forwardingFailAction == DEACTIVATE) {        // Just deactivate the processor
        log:printWarn("Maximum retry count exceeded when forwarding message to the HTTP endpoint " + config.httpEP
        + ". Message forwading is stopped for " + config.httpEP);
        config.onDeactivate();
    } else if (config.forwardingFailAction == DLC_STORE) {        // If there is a DLC store defined, store the message in it
        log:printWarn("Maximum retry count exceeded when forwarding message to the HTTP endpoint " + config.httpEP
        + ". Forwarding message to the DLC Store");
        Client? DLCStore = config["DLCStore"];
        if (DLCStore is Client) {
            error? storeResult = DLCStore->store(request);
            if (storeResult is error) {
                log:printError("Error while forwarding message to the DLC store. Message will be lost.", err = storeResult);
            } else {
                ackMessage(config, queueMessage);
            }
        } else {
            log:printError("Error while forwarding message to the DLC store. DLC store is not specified. Message will be lost");
            ackMessage(config, queueMessage);
        }
    } else {        // Drop the message and continue
        log:printWarn("Maximum retry count exceeded when forwarding message to the HTTP endpoint " + config.httpEP
        + ". Dropping message.");
        ackMessage(config, queueMessage);
    }
}

# Reconstruct construct HTTP message from JMS message.
#
# + message - JMS message (map message) `jms:Message`  
# + return - HTTP request `http:Request`
function constructHTTPRequest(jms:BytesMessage message) returns http:Request | error {
    byte[] payload = check message.readBytes();
    http:Request httpRequest = new();
    httpRequest.setBinaryPayload(<@untainted> payload);
    string[] propertyNames = check message.getPropertyNames();
    foreach var name in propertyNames {
        string|()|error value = message.getStringProperty(name);
        if (value is string) {
            httpRequest.setHeader(<@untainted> name, value);
        }
    }
    return httpRequest;
}


# Acknowledge message.
#
# + config - Config for message processor service `PollingServiceConfig`  
# + queueMessage - Message to acknowledge `jms:Message`
function ackMessage(PollingServiceConfig config, jms:Message queueMessage) {
    jms:MessageConsumer consumer = config.messageConsumer;
    var ack = queueMessage->acknowledge();
    if (ack is error) {
        log:printError("Error occurred while acknowledging message", err = ack);
    }
}

# Record carrying information on message forwarding status
#
# + success - `true` if forwarding message is successful
# + storeEmpty - `true` if message store is empty and no message is received
public type ForwardStatus record {
    boolean success;
    boolean storeEmpty;
};
