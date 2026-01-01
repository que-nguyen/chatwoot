class Webhooks::Trigger
  SUPPORTED_ERROR_HANDLE_EVENTS = %w[message_created message_updated].freeze

  def initialize(url, payload, webhook_type)
    @url = url
    @payload = payload
    @webhook_type = webhook_type
  end

  def self.execute(url, payload, webhook_type)
    new(url, payload, webhook_type).execute
  end

  def execute
    perform_request
  rescue StandardError => e
    handle_error(e)
    Rails.logger.warn "Exception: Invalid webhook URL #{@url} : #{e.message}"
  end

  private

  def perform_request
    payload_json = @payload.to_json
    headers = { content_type: :json, accept: :json }
    headers.merge!(api_inbox_signature_headers(payload_json))

    RestClient::Request.execute(
      method: :post,
      url: @url,
      payload: payload_json,
      headers: headers,
      timeout: webhook_timeout
    )
  end

  def api_inbox_signature_headers(payload_json)
    return {} unless @webhook_type == :api_inbox_webhook

    token = api_inbox_hmac_token
    return {} if token.blank?

    signature = OpenSSL::HMAC.hexdigest('sha256', token, payload_json)
    { 'X-Chatwoot-Signature' => "sha256=#{signature}" }
  end

  def api_inbox_hmac_token
    inbox_id = api_inbox_id
    return if inbox_id.blank?

    inbox = Inbox.find_by(id: inbox_id)
    return if inbox.blank?
    return if inbox.channel_type != 'Channel::Api'

    inbox.channel&.hmac_token
  end

  def api_inbox_id
    payload = @payload.respond_to?(:with_indifferent_access) ? @payload.with_indifferent_access : @payload

    payload[:inbox_id] ||
      payload.dig(:conversation, :inbox_id) ||
      payload.dig(:inbox, :id) ||
      payload.dig(:contact_inbox, :inbox, :id)
  end

  def handle_error(error)
    return unless SUPPORTED_ERROR_HANDLE_EVENTS.include?(@payload[:event])
    return unless message

    case @webhook_type
    when :agent_bot_webhook
      conversation = message.conversation
      return unless conversation&.pending?

      conversation.open!
      create_agent_bot_error_activity(conversation)
    when :api_inbox_webhook
      update_message_status(error)
    end
  end

  def create_agent_bot_error_activity(conversation)
    content = I18n.t('conversations.activity.agent_bot.error_moved_to_open')
    Conversations::ActivityMessageJob.perform_later(conversation, activity_message_params(conversation, content))
  end

  def activity_message_params(conversation, content)
    {
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: content
    }
  end

  def update_message_status(error)
    Messages::StatusUpdateService.new(message, 'failed', error.message).perform
  end

  def message
    return if message_id.blank?

    @message ||= Message.find_by(id: message_id)
  end

  def message_id
    @payload[:id]
  end

  def webhook_timeout
    raw_timeout = GlobalConfig.get_value('WEBHOOK_TIMEOUT')
    timeout = raw_timeout.presence&.to_i

    timeout&.positive? ? timeout : 5
  end
end
