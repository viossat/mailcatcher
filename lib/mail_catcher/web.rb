require "pathname"
require "net/http"
require "uri"

require "rack/builder"
require "sinatra"
require "skinny"

require "mail_catcher/events"
require "mail_catcher/mail"

class Sinatra::Request
  include Skinny::Helpers
end

module MailCatcher
  module Web extend self
    def call(env)
      app.call(env)
    end

    def app
      @app ||= if path = MailCatcher.options[:http_path]
                 Rack::Builder.new do
                   map path do
                     run Application
                   end
                   run lambda { |env| [302, {"Location" => path}, []] }
                 end
               else
                 Application
               end
    end

    class Application < Sinatra::Base
      set :environment, MailCatcher.env
      set :root, File.expand_path("#{__FILE__}/../../..")

      get "/" do
        send_file "public/index.html"
      end

      delete "/" do
        if MailCatcher.quittable?
          MailCatcher.quit!
          status 204
        else
          status 403
        end
      end

      get "/messages" do
        if request.websocket?
          request.websocket!(
            :on_start => proc do |websocket|
              subscription = Events::MessageAdded.subscribe do |message|
                begin
                  websocket.send_message(JSON.generate(message))
                rescue => exception
                  MailCatcher.log_exception("Error sending message through websocket", message, exception)
                end
              end

              websocket.on_close do |*|
                Events::MessageAdded.unsubscribe subscription
              end
            end)
        else
          content_type :json
          JSON.generate(Mail.messages)
        end
      end

      delete "/messages" do
        Mail.delete!
        status 204
      end

      get "/messages/:id.json" do
        id = params[:id].to_i
        if message = Mail.message(id)
          content_type :json
          JSON.generate(message.merge({
            "formats" => [
              "source",
              ("html" if Mail.message_has_html? id),
              ("plain" if Mail.message_has_plain? id)
            ].compact,
            "attachments" => Mail.message_attachments(id).map do |attachment|
              attachment.merge({"href" => "/messages/#{escape(id)}/parts/#{escape(attachment["cid"])}"})
            end,
          }))
        else
          not_found
        end
      end

      get "/messages/:id.html" do
        id = params[:id].to_i
        if part = Mail.message_part_html(id)
          content_type :html, :charset => (part["charset"] || "utf8")

          body = part["body"]

          # Rewrite body to link to embedded attachments served by cid
          body.gsub! /cid:([^'"> ]+)/, "#{id}/parts/\\1"

          body
        else
          not_found
        end
      end

      get "/messages/:id.plain" do
        id = params[:id].to_i
        if part = Mail.message_part_plain(id)
          content_type part["type"], :charset => (part["charset"] || "utf8")
          part["body"]
        else
          not_found
        end
      end

      get "/messages/:id.source" do
        id = params[:id].to_i
        if message = Mail.message(id)
          content_type "text/plain"
          message["source"]
        else
          not_found
        end
      end

      get "/messages/:id.eml" do
        id = params[:id].to_i
        if message = Mail.message(id)
          content_type "message/rfc822"
          message["source"]
        else
          not_found
        end
      end

      get "/messages/:id/parts/:cid" do
        id = params[:id].to_i
        if part = Mail.message_part_cid(id, params[:cid])
          content_type part["type"], :charset => (part["charset"] || "utf8")
          attachment part["filename"] if part["is_attachment"] == 1
          body part["body"].to_s
        else
          not_found
        end
      end

      delete "/messages/:id" do
        id = params[:id].to_i
        if Mail.message(id)
          Mail.delete_message!(id)
          status 204
        else
          not_found
        end
      end

      not_found do
        send_file "public/404.html"
      end
    end
  end
end
