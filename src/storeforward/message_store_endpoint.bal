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
import ballerina/math;
import ballerina/runtime;
import wso2/jms;


// Connector client for storing messages on a message broker
public type Client client object {

    // JMS connection related objects
    jms:Connection jmsConnection;
    jms:Session jmsSession;
    jms:MessageProducer messageProducer;

    // Secondary store client to use in case primary store client fails to send message to queue
    Client? secondaryStore;

    // Client config
    MessageStoreConfiguration storeConfig;

    // Queue name in broker where messages will be stored
    string queueName;


    # Initiliazes MessageStore client
    # 
    # + storeConfig - `MessageStoreConfiguration` with configurations
    # + return      - `error` if there is an issue initlaizing connection to configured broker
    public function __init(MessageStoreConfiguration storeConfig) returns error? {
        self.storeConfig = storeConfig;
        self.queueName = storeConfig.queueName;
        self.secondaryStore = storeConfig["secondaryStore"];
        var [connection, session, producer] = check self.intializeMessageSender(storeConfig);
        self.jmsConnection = connection;
        self.jmsSession = session;
        self.messageProducer = producer;
    }

    # Stores HTTP message. This has resiliency for the delivery of the message to the message broker queue
    # accroding to `MessageStoreRetryConfig`. Will return an `error` of all reries are elapsed, and if all retries 
    # configured to secondary message store are elapsed (if one specified)
    # 
    # + message - HTTP message to store 
    # + return - `error` if there is an issue storing the message (i.e connection issue with broker) 
    public remote function store(http:Request message) returns @tainted error? {

        // Set request headers
        map<string> requestMessageHeadersMap = {};
        foreach var headerName in message.getHeaderNames() {
            requestMessageHeadersMap[headerName] = message.getHeader(<@untainted> headerName);
        }
        // Set request payload
        byte[] binaryPayload = check message.getBinaryPayload();
        // Send message to be stored
        var storeSendResult = self.tryToSendMessage(binaryPayload, requestMessageHeadersMap);

        if (storeSendResult is error) {
            MessageStoreRetryConfig? retryConfig = self.storeConfig?.retryConfig;
            // Give up if there is no resiliency
            if (retryConfig is ()) {
                return storeSendResult;
            } else {
                int retryCount = 0;
                while (retryCount < retryConfig.count) {
                    int currentRetryCount = retryCount + 1;
                    log:printWarn("Error while sending message to queue " + self.queueName
                    + ". Retrying to send message. Retry count = " + currentRetryCount.toString());
                    boolean reTrySuccessful = true;
                    var reInitClientResult = self.reInitializeClient(self.storeConfig);
                    if (reInitClientResult is error) {
                        log:printError("Error while re-initializing store client to queue "
                        + self.queueName, err = reInitClientResult);
                        reTrySuccessful = false;
                    } else {
                        var storeResult = self.tryToSendMessage(binaryPayload, requestMessageHeadersMap);
                        if (storeResult is error) {
                            log:printError("Error while trying to store message to queue"
                            + self.queueName, err = storeResult);
                            reTrySuccessful = false;
                        } else {
                            // Sending successful
                            break;
                        }
                    }
                    if (!reTrySuccessful) {
                        int retryDelay = retryConfig.interval
                        + math:round(retryCount * retryConfig.interval * retryConfig.backOffFactor);
                        if (retryDelay > retryConfig.maxWaitInterval) {
                            retryDelay = retryConfig.maxWaitInterval;
                        }
                        runtime:sleep(retryDelay * 1000);
                        retryCount = retryCount + 1;
                    }
                }
                log:printError("Maximum retry count to store message in queue = " + self.queueName + " exceeded");

                // If number of max retry count exceeds, try with secondary store
                if (retryCount >= retryConfig.count) {
                    Client? failoverClient = self.secondaryStore;
                    if (failoverClient is Client) {
                        log:printInfo("Trying to store message in secondary configured for message store queue = "
                            + self.queueName);
                        var failOverClientStoreResult = failoverClient->store(message);
                        if (failOverClientStoreResult is error) {
                            return failOverClientStoreResult;
                        }
                    } else {
                        // If no secondary store is provided, return primary store error
                        return storeSendResult;
                    }
                }
            }
        }
    }


    # Try to send the message to message broker queue.
    #
    # + payload - The http payload to be persisted as a JMS Bytes Message in the message store
    # + headers - The http headers to be persisted as properties in the JMS bytes message
    # + return - `error` in case of an issue sending the message to the queue
    function tryToSendMessage(byte[] payload, map<string> headers) returns error? {
        // Create a JMS Bytes Message
        jms:BytesMessage bytesMessage = check self.jmsSession.createByteMessage();

        // Write message body
        error|() result = bytesMessage.writeBytes(payload);
        if (result is error) {
            return result;
        }
        // Set http headers as JMS properties
        foreach var [name, value] in headers.entries() {
            result = bytesMessage.setStringProperty(name, value);
            if (result is error) {
                return result;
            }
        }
        // Send the message to the JMS provider
        var returnVal = self.messageProducer->send(bytesMessage);
        if (returnVal is error) {
            return returnVal;
        }
    }

    
    # Intialize connection, session and sender to the message broker. 
    #
    # + storeConfig -  `MessageStoreConfiguration` config of message store 
    # + return - Created JMS objects as `(jms:Connection, jms:Session, jms:MessageProducer)` or an `error` in case of an issue
    function intializeMessageSender(MessageStoreConfiguration storeConfig)
                    returns [jms:Connection, jms:Session, jms:MessageProducer]|error {

        // Initialize JMS connection with the provider
        jms:Connection jmsConnection = check jms:createConnection({
                                          initialContextFactory: getInitialContextFactory(storeConfig.messageBroker),
                                          providerUrl: storeConfig.providerUrl,
                                          username: storeConfig["userName"],
                                          password: storeConfig["password"]
                                       });

        // Initialize JMS session on top of the created connection
        jms:Session jmsSession = check jmsConnection->createSession({acknowledgementMode: "AUTO_ACKNOWLEDGE"});

        // Initialize queue sender
        jms:Destination queue = check jmsSession->createQueue(storeConfig.queueName);
        jms:MessageProducer messageProducer = check jmsSession.createProducer(queue);

        return [jmsConnection, jmsSession, messageProducer];
    }


    # Close message sender and related JMS connections. 
    #
    # + return - `error` in case of closing 
    function closeMessageSender() returns error? {
        self.jmsConnection->stop();
    }


    # Reinitialiaze Message Store client. 
    # 
    # + storeConfig - Configuration to initialize message store 
    # + return - `error` in case of initalization issue (i.e. connection to broker could not be established)
    function reInitializeClient(MessageStoreConfiguration storeConfig) returns error? {
        check self.closeMessageSender();
        var [connection, session, producer] = check self.intializeMessageSender(storeConfig);
        self.jmsConnection = connection;
        self.jmsSession = session;
        self.messageProducer = producer;
    }
};

# Configuration for Message Store.MessageForwardingProcessor 
#
# + messageBroker - Message broker store will connecting to
# + secondaryStore - Secondary Store which is used when primary store is not reachable (optional)
# + retryConfig - `MessageStoreRetryConfig` related to resiliency of message store client (optional)
# + providerUrl - Connection url pointing to message broker
# + queueName - Messages will be stored to this queue on the broker
# + userName - UserName to use when connecting to the broker (optional)
# + password - Password to use when connecting to the broker (optional)
public type MessageStoreConfiguration record {|
    MessageBroker messageBroker;
    Client secondaryStore?;
    MessageStoreRetryConfig retryConfig?;
    string providerUrl;
    string queueName;
    string userName?;
    string password?;
|};

# Message Store retry configuration. Message store will retry to store a message 
# according to this config retrying to connect to message broker. In message processor 
# same config will be use to retry polling a message from the message broker.
#
# + interval - Time interval to attempt connecting to broker (seconds). Each time this time
#              get multiplied by `backOffFactor` until `maxWaitInterval`
#              is reached
# + count - Number of retry attempts before giving up
# + backOffFactor - Multiplier of the retry `interval` 
# + maxWaitInterval - Max time interval to attempt connecting to broker (seconds) and resend
public type MessageStoreRetryConfig record {|
    int interval = 5;
    int count;
    float backOffFactor = 1.5;
    int maxWaitInterval = 60;
|};
